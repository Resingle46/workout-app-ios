import type {
  CoachChatRequest,
  CoachProfileInsightsRequest,
} from "./schemas";

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

export function buildProfileInsightsMessages(
  request: CoachProfileInsightsRequest
): Array<{ role: "system" | "user"; content: string }> {
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
        "Context JSON:",
        JSON.stringify(request.context),
      ].join("\n\n"),
    },
  ];
}

export function buildChatMessages(
  request: CoachChatRequest
): Array<{ role: "system" | "user"; content: string }> {
  return [
    {
      role: "system",
      content: [
        sharedRules(request.locale),
        "Task: answer the user's training question using the supplied app context.",
        "Return markdown in answerMarkdown when formatting helps, but keep it compact.",
        "Include up to 4 follow-up questions that naturally continue the conversation.",
      ].join("\n\n"),
    },
    {
      role: "user",
      content: [
        `Capability scope: ${request.capabilityScope}`,
        `Question: ${request.question}`,
        "Return JSON that strictly matches the provided schema.",
        "Current app context JSON:",
        JSON.stringify(request.context),
      ].join("\n\n"),
    },
  ];
}
