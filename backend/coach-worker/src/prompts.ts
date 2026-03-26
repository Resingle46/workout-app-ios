import type {
  CoachChatRequest,
  CoachProfileInsightsRequest,
} from "./schemas";
import { buildInferencePromptContext } from "./context";

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
    "If the saved note explicitly says not to change weekly frequency or workout count, respect that and return no conflicting suggestedChanges.",
    "Stay within workout programming, progression, recovery, and adherence guidance.",
    "Do not give medical diagnosis, treatment plans, or supplement protocols.",
    "Only emit suggestedChanges that exactly match one of the supported types:",
    "- setWeeklyWorkoutTarget",
    "- addWorkoutDay",
    "- deleteWorkoutDay",
    "- swapWorkoutExercise",
    "- updateTemplateExercisePrescription",
    "Only emit a suggested change when the required IDs and fields are present in the supplied context.",
    "If a safe or exact draft change cannot be supported from the supplied data, return an empty suggestedChanges array.",
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

export function buildProfileInsightsMessages(
  request: CoachProfileInsightsRequest
): PromptMessage[] {
  return [
    {
      role: "system",
      content: [
        sharedRules(request.locale),
        "Task: analyze the user's current training state and return a compact coach summary, concrete recommendations, and optional draft changes.",
        "Prefer high-signal observations over generic motivation.",
        "Do not mention missing data unless it materially limits the advice.",
      ].join("\n\n"),
    },
    {
      role: "user",
      content: [
        `Capability scope: ${request.capabilityScope}`,
        "Return JSON that strictly matches the provided schema.",
        ...coachAnalysisContextLines(request.snapshot),
      ].join("\n\n"),
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
        "Do not include a 'Suggested Changes' section, raw field names, or schema-like dumps inside answerMarkdown.",
        "If you want to propose changes, put them only in suggestedChanges.",
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
        `Capability scope: ${request.capabilityScope}`,
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
        "Do not include suggested changes in the fallback response.",
      ].join("\n\n"),
    },
    {
      role: "user",
      content: [
        `Capability scope: ${request.capabilityScope}`,
        ...coachAnalysisContextLines(request.snapshot),
      ].join("\n\n"),
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
        "Do not include a 'Suggested Changes' section, raw field names, or code fences.",
      ].join("\n\n"),
    },
    ...request.clientRecentTurns.map((message) => ({
      role: message.role,
      content: message.content,
    })),
    {
      role: "user",
      content: [
        `Capability scope: ${request.capabilityScope}`,
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
