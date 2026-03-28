import type {
  CoachChatRequest,
  CoachProfileInsightsRequest,
  CoachWorkoutSummaryJobCreateRequest,
} from "./schemas";
import {
  buildDerivedCoachAnalyticsFromCompactSnapshot,
  buildInferencePromptContext,
  buildProfileInsightsPromptContext,
  type CoachContextProfile,
  type CoachDerivedAnalytics,
} from "./context";

type PromptMessage = {
  role: "system" | "user" | "assistant";
  content: string;
};

type CoachAnalysisContextOptions = {
  contextProfile?: CoachContextProfile;
  derivedAnalytics?: CoachDerivedAnalytics;
  includeCoachAnalysisSettings?: boolean;
  includePreferredProgram?: boolean;
  includeUserComment?: boolean;
  includeSanitizedContext?: boolean;
};

type PromptBuildOptions = {
  contextProfile?: CoachContextProfile;
  derivedAnalytics?: CoachDerivedAnalytics;
};

function localeInstruction(locale: string): string {
  return locale.toLowerCase().startsWith("ru")
    ? "Write all user-facing text in Russian."
    : "Write all user-facing text in English.";
}

function sharedRules(locale: string): string {
  return [
    "You are WorkoutApp Coach, an internal AI training assistant embedded in a workout app.",
    localeInstruction(locale),
    "Use only the provided app context. Do not invent profile, workout, progress, or program-structure facts.",
    "Use the full context before responding: recent sessions, adherence, progression, PRs, preferred program, saved note, and derived analytics.",
    "Treat explicit user-authored execution notes in programComment as authoritative when they describe how the user actually runs the plan.",
    "If the user says they rotate through templates in sequence, treat that as a legitimate execution model rather than a structural mistake.",
    "If derived analytics are present, treat them as the authoritative interpretation layer over title-based heuristics.",
    "Stay inside workout programming, progression, recovery, execution quality, and adherence guidance.",
    "Separate what is clearly supported from what is only cautiously inferred. If evidence is partial, lower confidence instead of going silent.",
    "Do not give medical diagnosis, treatment plans, or supplement protocols.",
    "Write recommendations as plain coaching advice, not as app actions or structured field dumps.",
    "Do not mention internal IDs, schema fields, or JSON keys.",
    "Be specific, useful, and evidence-first. Avoid generic motivation.",
  ].join("\n");
}

function isRichContextProfile(contextProfile: CoachContextProfile | undefined): boolean {
  return (
    contextProfile === "rich_async_v1" ||
    contextProfile === "rich_async_analytics_v1"
  );
}

function resolveDerivedAnalytics(
  snapshot: CoachProfileInsightsRequest["snapshot"] | CoachChatRequest["snapshot"],
  options: PromptBuildOptions
): CoachDerivedAnalytics | undefined {
  if (options.derivedAnalytics) {
    return options.derivedAnalytics;
  }

  if (!snapshot) {
    return undefined;
  }

  return buildDerivedCoachAnalyticsFromCompactSnapshot(snapshot);
}

function highPriorityConstraintLines(
  snapshot: CoachProfileInsightsRequest["snapshot"] | CoachChatRequest["snapshot"]
): string[] {
  if (!snapshot) {
    return [];
  }

  const promptContext = buildInferencePromptContext(snapshot);
  const lines: string[] = [];

  if (promptContext.userConstraints.rollingSplitExecution) {
    lines.push(
      "- The user explicitly says they rotate workouts/templates in sequence instead of matching template count to calendar-week sessions."
    );
  }

  if (promptContext.userConstraints.statedWeeklyFrequency !== undefined) {
    lines.push(
      `- The user explicitly states they train ${promptContext.userConstraints.statedWeeklyFrequency} times per week.`
    );
  }

  if (promptContext.userConstraints.preserveWeeklyFrequency) {
    lines.push("- Do not recommend changing weekly training frequency.");
  }

  if (promptContext.userConstraints.preserveProgramWorkoutCount) {
    lines.push("- Do not recommend changing the number of workout days/templates in the saved program.");
  }

  if (promptContext.analytics.derived?.splitExecution.explanation) {
    lines.push(
      `- Execution interpretation: ${promptContext.analytics.derived.splitExecution.explanation}`
    );
  }

  return lines;
}

function coachAnalysisContextLines(
  snapshot: CoachProfileInsightsRequest["snapshot"] | CoachChatRequest["snapshot"],
  options: CoachAnalysisContextOptions = {}
): string[] {
  if (!snapshot) {
    return [];
  }

  const {
    contextProfile = "compact_sync_v2",
    derivedAnalytics = resolveDerivedAnalytics(snapshot, options),
    includeCoachAnalysisSettings = true,
    includePreferredProgram = true,
    includeUserComment = true,
    includeSanitizedContext = true,
  } = options;
  const promptContext = buildInferencePromptContext(snapshot, {
    contextProfile,
    derivedAnalytics,
  });
  const lines: string[] = [];

  if (includeCoachAnalysisSettings) {
    lines.push(
      "Coach analysis settings JSON:",
      JSON.stringify(snapshot.coachAnalysisSettings)
    );
  }

  if (includePreferredProgram && promptContext.preferredProgram) {
    lines.push(
      "Selected program for analysis JSON:",
      JSON.stringify(promptContext.preferredProgram)
    );
  }

  const comment = snapshot.coachAnalysisSettings.programComment.trim();
  if (includeUserComment && comment) {
    lines.push(`User comment about how they actually run the program: ${comment}`);
  }

  const constraintLines = highPriorityConstraintLines(snapshot);
  if (constraintLines.length > 0) {
    lines.push("High-priority user constraints:");
    lines.push(...constraintLines);
  }

  if (includeSanitizedContext) {
    lines.push(
      isRichContextProfile(contextProfile)
        ? "Coach context JSON:"
        : "Sanitized coach context JSON:"
    );
    lines.push(JSON.stringify(promptContext));
  }

  if (promptContext.analytics.training) {
    lines.push("Training recommendation JSON:");
    lines.push(JSON.stringify(promptContext.analytics.training));
  }

  if (promptContext.analytics.compatibility) {
    lines.push("Compatibility assessment JSON:");
    lines.push(JSON.stringify(promptContext.analytics.compatibility));
  }

  if (promptContext.analytics.derived) {
    lines.push("Derived coach analytics JSON:");
    lines.push(JSON.stringify(promptContext.analytics.derived));
  }

  return lines;
}

function profileInsightsContextLines(
  snapshot: CoachProfileInsightsRequest["snapshot"],
  options: PromptBuildOptions = {}
): string[] {
  if (!snapshot) {
    return [];
  }

  const contextProfile = options.contextProfile ?? "compact_sync_v2";
  const derivedAnalytics = resolveDerivedAnalytics(snapshot, options);
  const promptContext = buildProfileInsightsPromptContext(snapshot, {
    contextProfile,
    derivedAnalytics,
  });
  const avoidStructureFocus =
    promptContext.userConstraints.rollingSplitExecution ||
    promptContext.userConstraints.preserveWeeklyFrequency ||
    promptContext.userConstraints.preserveProgramWorkoutCount ||
    promptContext.derived?.splitExecution.mode === "rolling_rotation";
  const comment = snapshot.coachAnalysisSettings.programComment.trim();
  const lines: string[] = [];

  if (comment) {
    lines.push(`Saved user note: ${comment}`);
  }

  const constraintLines = highPriorityConstraintLines(snapshot);
  if (constraintLines.length > 0) {
    lines.push("High-priority user constraints:");
    lines.push(...constraintLines);
  }
  if (avoidStructureFocus) {
    lines.push(
      "Focus guidance: treat rolling rotation and template count versus weekly target as already-resolved execution context, not as the main coaching problem."
    );
  }

  if (promptContext.preferredProgram) {
    lines.push(
      "Program coverage guidance: treat the preferred program summary as authoritative proof of which workouts and exercises are already included."
    );
    lines.push(
      "Do not ask the user to verify whether a workout, exercise, or muscle group is included unless the program summary explicitly shows a real gap."
    );
  }

  if (promptContext.derived) {
    lines.push("Execution interpretation JSON:");
    lines.push(JSON.stringify(promptContext.derived.splitExecution));
    lines.push("Claim confidence JSON:");
    lines.push(JSON.stringify(promptContext.derived.claimConfidence));
  }

  if (promptContext.derived && !promptContext.derived.supportedClaims.muscleExposure) {
    lines.push(
      "Evidence guidance: muscle exposure claims should stay cautious because the available support is weaker than fully supported."
    );
  }

  lines.push("Goal summary JSON:");
  lines.push(JSON.stringify(promptContext.goal));
  lines.push("Consistency summary JSON:");
  lines.push(JSON.stringify(promptContext.consistency));
  lines.push("30-day progress JSON:");
  lines.push(JSON.stringify(promptContext.progress30Days));

  if (promptContext.training) {
    lines.push("Training recommendation JSON:");
    lines.push(JSON.stringify(promptContext.training));
  }

  if (promptContext.compatibility) {
    lines.push("Compatibility assessment JSON:");
    lines.push(JSON.stringify(promptContext.compatibility));
  }

  if (promptContext.recentPersonalRecords.length > 0) {
    lines.push("Recent personal records JSON:");
    lines.push(JSON.stringify(promptContext.recentPersonalRecords));
  }

  if (promptContext.relativeStrength.length > 0) {
    lines.push("Relative strength JSON:");
    lines.push(JSON.stringify(promptContext.relativeStrength));
  }

  if (promptContext.recentFinishedSessions.length > 0) {
    lines.push("Recent finished sessions JSON:");
    lines.push(JSON.stringify(promptContext.recentFinishedSessions));
  }

  if (promptContext.preferredProgram) {
    lines.push("Preferred program summary JSON:");
    lines.push(JSON.stringify(promptContext.preferredProgram));
  }

  if (promptContext.derived) {
    lines.push("Derived coach analytics JSON:");
    lines.push(JSON.stringify(promptContext.derived));
  }

  return lines;
}

function workoutSummaryContextLines(
  request: CoachWorkoutSummaryJobCreateRequest
): string[] {
  return [
    `Request mode: ${request.requestMode}`,
    `Trigger: ${request.trigger}`,
    `Input mode: ${request.inputMode}`,
    "Current workout JSON:",
    JSON.stringify(request.currentWorkout),
    "Recent same-exercise history JSON:",
    JSON.stringify(request.recentExerciseHistory),
  ];
}

export function buildProfileInsightsMessages(
  request: CoachProfileInsightsRequest,
  options: PromptBuildOptions = {}
): PromptMessage[] {
  const contextProfile = options.contextProfile ?? "compact_sync_v2";
  const promptContext = request.snapshot
    ? buildProfileInsightsPromptContext(request.snapshot, {
        contextProfile,
        derivedAnalytics: resolveDerivedAnalytics(request.snapshot, options),
      })
    : undefined;
  const avoidStructureFocus =
    promptContext?.userConstraints.rollingSplitExecution ||
    promptContext?.userConstraints.preserveWeeklyFrequency ||
    promptContext?.userConstraints.preserveProgramWorkoutCount ||
    promptContext?.derived?.splitExecution.mode === "rolling_rotation";
  return [
    {
      role: "system",
      content: [
        sharedRules(request.locale),
        "Task: produce a detailed coach profile-insights brief grounded in the supplied context and derived analytics.",
        "Quality is more important than brevity. Use the whole context before deciding what matters most.",
        "Write a real coach summary, not a compact fallback paragraph.",
        "Start from the user's actual execution model, especially any user-authored note about rolling rotation, sequential execution, or protected weekly frequency.",
        "Treat rolling rotation as legitimate when the note or derived interpretation supports it. Do not frame it as a program mistake.",
        "Use recent sessions, adherence, progression, PRs, preferred program structure, and the saved note together.",
        "Promote hard evidence into confident observations. When evidence is partial, keep the observation but lower confidence and explain why.",
        "Do not mention missing data unless it materially limits the advice.",
        "Do not collapse into generic encouragement.",
        promptContext?.preferredProgram
          ? "Treat the provided preferred-program summary as authoritative. Do not tell the user to verify whether workouts, exercises, or muscle groups are included unless the summary itself shows a real gap."
          : undefined,
        promptContext?.derived && !promptContext.derived.supportedClaims.muscleExposure
          ? "When discussing muscle exposure, explicitly keep the language cautious unless derived analytics mark the claim as supported."
          : undefined,
        avoidStructureFocus
          ? "Do not spend the response on workout-template count, split mismatch, or weekly-target mismatch. Treat the execution note as already resolved and focus on progression, adherence, recovery, concentration, and next-step coaching."
          : undefined,
        "Return JSON with these sections:",
        "- summary: 2 to 5 sentences synthesizing the main coaching picture.",
        "- keyObservations: 3 to 6 evidence-based observations tied to the supplied context.",
        "- topConstraints: the main factors shaping what the user can or should do next.",
        "- recommendations: 3 to 6 concrete next-step coaching recommendations.",
        "- confidenceNotes: short notes for caveats, partial support, or cautious hypotheses.",
        "- executionContext: reflect the authoritative execution interpretation when available.",
      ]
        .filter((value): value is string => Boolean(value))
        .join("\n\n"),
    },
    {
      role: "user",
      content: [
        "Return JSON that strictly matches the provided schema.",
        ...profileInsightsContextLines(request.snapshot, options),
      ].join("\n"),
    },
  ];
}

export function buildChatMessages(
  request: CoachChatRequest,
  options: PromptBuildOptions = {}
): PromptMessage[] {
  const contextProfile = options.contextProfile ?? "compact_sync_v2";
  return [
    {
      role: "system",
      content: [
        sharedRules(request.locale),
        "Task: answer the user's training question using the supplied app context.",
        "Use the supplied recent conversation turns only as short-term context. The current app context in the final user message is authoritative.",
        isRichContextProfile(contextProfile)
          ? "Return markdown in answerMarkdown when formatting helps. Use enough detail to stay precise and well-supported."
          : "Return markdown in answerMarkdown when formatting helps, but keep it compact.",
        "Prefer short paragraphs or bullet lists instead of one dense block of text.",
        "Leave a blank line between distinct sections.",
        "Do not repeat the user's question as a heading.",
        "For pros and cons, comparisons, split-day suggestions, or multi-part answers, use bullets.",
        "If you want to propose changes, write them directly in answerMarkdown as normal prose or bullets.",
        "Do not include raw field names, internal IDs, or schema-like dumps inside answerMarkdown.",
        "Avoid code fences unless the user explicitly asks for code.",
        "Include up to 3 short follow-up prompts that the user could tap and send back to the coach as their next message.",
        "Write followUps from the user's perspective as direct requests or questions to the coach.",
        "Do not write questions that the coach should ask the user.",
        "Bad followUp: 'Do you want to change your program?'",
        "Good followUps: 'Help me change my program.', 'Compare this with upper/lower.', 'Give me a 3-day version.'",
      ].join("\n\n"),
    },
    ...request.clientRecentTurns.map((message) => ({
      role: message.role,
      content: message.content,
    })),
    {
      role: "user",
      content: [
        `Question: ${request.question}`,
        "Return JSON that strictly matches the provided schema.",
        ...coachAnalysisContextLines(request.snapshot, {
          contextProfile,
          derivedAnalytics: resolveDerivedAnalytics(request.snapshot, options),
          includeCoachAnalysisSettings: isRichContextProfile(contextProfile),
          includePreferredProgram: isRichContextProfile(contextProfile),
          includeUserComment: true,
        }),
      ].join("\n\n"),
    },
  ];
}

export function buildFallbackProfileInsightsMessages(
  request: CoachProfileInsightsRequest,
  options: PromptBuildOptions = {}
): PromptMessage[] {
  const contextProfile = options.contextProfile ?? "compact_sync_v2";
  const promptContext = request.snapshot
    ? buildProfileInsightsPromptContext(request.snapshot, {
        contextProfile,
        derivedAnalytics: resolveDerivedAnalytics(request.snapshot, options),
      })
    : undefined;
  return [
    {
      role: "system",
      content: [
        sharedRules(request.locale),
        "Task: analyze the user's current training state and return plain markdown only.",
        "Do not return JSON.",
        "Use exactly these English section labels so the response can be parsed reliably:",
        "Summary: <2 to 5 sentence synthesis>",
        "Key observations:",
        "- <2 to 5 bullets>",
        "Constraints:",
        "- <0 to 4 bullets>",
        "Recommendations:",
        "- <2 to 5 bullets>",
        "Confidence notes:",
        "- <0 to 3 bullets>",
        "Execution context:",
        "- <0 to 3 bullets>",
        "Keep the user-facing text itself in the requested locale.",
        promptContext?.preferredProgram
          ? "Treat the provided preferred-program summary as authoritative. Do not tell the user to verify whether workouts, exercises, or muscle groups are included unless the summary itself shows a real gap."
          : undefined,
        promptContext?.derived && !promptContext.derived.supportedClaims.muscleExposure
          ? "If muscle exposure reasoning is weaker than supported, make it explicitly cautious instead of stating it as a hard fact."
          : undefined,
        "Prefer concrete progression, recovery, adherence, concentration, and plan-execution advice over generic coverage checks.",
      ]
        .filter((value): value is string => Boolean(value))
        .join("\n\n"),
    },
    {
      role: "user",
      content: [
        ...profileInsightsContextLines(request.snapshot, options),
      ].join("\n"),
    },
  ];
}

export function buildFallbackChatMessages(
  request: CoachChatRequest,
  options: PromptBuildOptions = {}
): PromptMessage[] {
  const contextProfile = options.contextProfile ?? "compact_sync_v2";
  return [
    {
      role: "system",
      content: [
        sharedRules(request.locale),
        "Task: answer the user's training question using the supplied app context.",
        "Use the supplied recent conversation turns only as short-term context. The current app context in the final user message is authoritative.",
        "Return a concise markdown answer only. Do not return JSON.",
        "Prefer short paragraphs or bullet lists instead of one dense block of text.",
        "Leave a blank line between distinct sections.",
        "Do not repeat the user's question as a heading.",
        "For pros and cons, comparisons, split-day suggestions, or multi-part answers, use bullets.",
        "If you propose changes, write them directly in the answer as normal prose or bullets.",
        "Do not include raw field names, internal IDs, or code fences.",
      ].join("\n\n"),
    },
    ...request.clientRecentTurns.map((message) => ({
      role: message.role,
      content: message.content,
    })),
    {
      role: "user",
      content: [
        `Question: ${request.question}`,
        ...coachAnalysisContextLines(request.snapshot, {
          contextProfile,
          derivedAnalytics: resolveDerivedAnalytics(request.snapshot, options),
          includeCoachAnalysisSettings: isRichContextProfile(contextProfile),
          includePreferredProgram: isRichContextProfile(contextProfile),
          includeUserComment: true,
        }),
      ].join("\n\n"),
    },
  ];
}

export function buildWorkoutSummaryMessages(
  request: CoachWorkoutSummaryJobCreateRequest
): PromptMessage[] {
  return [
    {
      role: "system",
      content: [
        sharedRules(request.locale),
        "Task: write a compact post-workout summary for the workout completion screen.",
        "Focus on what happened in this workout and on the most relevant comparison against recent same-exercise history.",
        "Do not mention internal IDs, schema keys, cache behavior, fingerprints, or backend mechanics.",
        "Do not mention that the text was generated by AI.",
        "Keep the headline short, the summary to one compact paragraph, and highlights/action points specific.",
        "Only mention trends that are supported by the provided current workout and recent same-exercise history.",
      ].join("\n\n"),
    },
    {
      role: "user",
      content: [
        "Return JSON that strictly matches the provided schema.",
        ...workoutSummaryContextLines(request),
      ].join("\n"),
    },
  ];
}

export function buildFallbackWorkoutSummaryMessages(
  request: CoachWorkoutSummaryJobCreateRequest
): PromptMessage[] {
  return [
    {
      role: "system",
      content: [
        sharedRules(request.locale),
        "Task: write a compact post-workout summary for the workout completion screen.",
        "Do not return JSON.",
        "Use exactly these English section labels so the response can be parsed reliably:",
        "Headline: <short user-facing headline>",
        "Summary: <one short paragraph>",
        "Highlights:",
        "- <2 to 4 bullets>",
        "Next workout focus:",
        "- <0 to 3 bullets>",
        "Keep the user-facing text itself in the requested locale.",
      ].join("\n\n"),
    },
    {
      role: "user",
      content: workoutSummaryContextLines(request).join("\n"),
    },
  ];
}
