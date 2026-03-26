import type {
  CoachChatRequest,
  CoachProfileInsightsRequest,
} from "./schemas";
import {
  buildInferencePromptContext,
  buildProfileInsightsPromptContext,
} from "./context";

type PromptMessage = {
  role: "system" | "user" | "assistant";
  content: string;
};

type CoachAnalysisContextOptions = {
  includeCoachAnalysisSettings?: boolean;
  includePreferredProgram?: boolean;
  includeUserComment?: boolean;
  includeSanitizedContext?: boolean;
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
    "Use only the provided app context. Do not invent profile, workout, or progress facts.",
    "Treat explicit user-authored execution notes in programComment as higher priority than heuristic assumptions about split structure or weekly frequency.",
    "If the user says they rotate through more workout templates than they perform each week, do not treat that alone as a mismatch.",
    "If the saved note explicitly says not to change weekly frequency or workout count, respect that in your advice.",
    "Stay within workout programming, progression, recovery, and adherence guidance.",
    "Do not give medical diagnosis, treatment plans, or supplement protocols.",
    "Write recommendations as plain coaching advice, not as app actions or structured field dumps.",
    "Do not mention internal IDs, schema fields, or JSON keys.",
    "Be concise and specific.",
  ].join("\n");
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
      "- The user says they rotate workouts/templates in order instead of matching template count to weekly sessions."
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

  return lines;
}

function coachAnalysisContextLines(
  snapshot: CoachProfileInsightsRequest["snapshot"] | CoachChatRequest["snapshot"],
  options: CoachAnalysisContextOptions = {}
): string[] {
  if (!snapshot) {
    return [];
  }

  const promptContext = buildInferencePromptContext(snapshot);
  const {
    includeCoachAnalysisSettings = true,
    includePreferredProgram = true,
    includeUserComment = true,
    includeSanitizedContext = true,
  } = options;
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
    lines.push("Sanitized coach context JSON:");
    lines.push(JSON.stringify(promptContext));
  }

  return lines;
}

function profileInsightsContextLines(
  snapshot: CoachProfileInsightsRequest["snapshot"]
): string[] {
  if (!snapshot) {
    return [];
  }

  const promptContext = buildProfileInsightsPromptContext(snapshot);
  const comment = snapshot.coachAnalysisSettings.programComment.trim();
  const lines: string[] = [];

  if (comment) {
    lines.push(`Saved user note: ${comment.slice(0, 220)}`);
  }

  const constraintLines = highPriorityConstraintLines(snapshot);
  if (constraintLines.length > 0) {
    lines.push("High-priority user constraints:");
    lines.push(...constraintLines);
  }

  lines.push("Goal summary JSON:");
  lines.push(JSON.stringify(promptContext.goal));
  lines.push("Consistency summary JSON:");
  lines.push(JSON.stringify(promptContext.consistency));
  lines.push("30-day progress JSON:");
  lines.push(JSON.stringify(promptContext.progress30Days));

  if (promptContext.recentPersonalRecords.length > 0) {
    lines.push("Recent personal records JSON:");
    lines.push(JSON.stringify(promptContext.recentPersonalRecords));
  }

  if (promptContext.relativeStrength.length > 0) {
    lines.push("Relative strength JSON:");
    lines.push(JSON.stringify(promptContext.relativeStrength));
  }

  if (promptContext.preferredProgram) {
    lines.push("Preferred program summary JSON:");
    lines.push(JSON.stringify(promptContext.preferredProgram));
  }

  return lines;
}

export function buildProfileInsightsMessages(
  request: CoachProfileInsightsRequest
): PromptMessage[] {
  return [
    {
      role: "system",
      content: [
        sharedRules(request.locale),
        "Task: analyze the user's current training state and return a compact coach summary with concrete recommendations.",
        "Prefer high-signal observations over generic motivation.",
        "Do not mention missing data unless it materially limits the advice.",
      ].join("\n\n"),
    },
    {
      role: "user",
      content: [
        "Return JSON that strictly matches the provided schema.",
        ...profileInsightsContextLines(request.snapshot),
      ].join("\n"),
    },
  ];
}

export function buildChatMessages(
  request: CoachChatRequest
): PromptMessage[] {
  return [
    {
      role: "system",
      content: [
        sharedRules(request.locale),
        "Task: answer the user's training question using the supplied app context.",
        "Use the supplied recent conversation turns only as short-term context. The current app context in the final user message is authoritative.",
        "Return markdown in answerMarkdown when formatting helps, but keep it compact.",
        "Do not repeat the user's question as a heading.",
        "If you want to propose changes, write them directly in answerMarkdown as normal prose or bullets.",
        "Do not include raw field names, internal IDs, or schema-like dumps inside answerMarkdown.",
        "Avoid code fences unless the user explicitly asks for code.",
        "Include up to 4 follow-up questions that naturally continue the conversation.",
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
          includeCoachAnalysisSettings: false,
          includePreferredProgram: false,
          includeUserComment: false,
        }),
      ].join("\n\n"),
    },
  ];
}

export function buildFallbackProfileInsightsMessages(
  request: CoachProfileInsightsRequest
): PromptMessage[] {
  return [
    {
      role: "system",
      content: [
        sharedRules(request.locale),
        "Task: analyze the user's current training state and return plain markdown only.",
        "Do not return JSON.",
        "Write one short summary paragraph first.",
        "Then write up to 4 compact bullet recommendations.",
        "If you propose changes, write them as plain recommendations only.",
      ].join("\n\n"),
    },
    {
      role: "user",
      content: [
        ...profileInsightsContextLines(request.snapshot),
      ].join("\n"),
    },
  ];
}

export function buildFallbackChatMessages(
  request: CoachChatRequest
): PromptMessage[] {
  return [
    {
      role: "system",
      content: [
        sharedRules(request.locale),
        "Task: answer the user's training question using the supplied app context.",
        "Use the supplied recent conversation turns only as short-term context. The current app context in the final user message is authoritative.",
        "Return a concise markdown answer only. Do not return JSON.",
        "Do not repeat the user's question as a heading.",
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
          includeCoachAnalysisSettings: false,
          includePreferredProgram: false,
          includeUserComment: false,
        }),
      ].join("\n\n"),
    },
  ];
}
