import { createApp } from "./app";
export { CoachChatJobWorkflow } from "./chat-job-workflow";
export { ProfileInsightsJobWorkflow } from "./profile-insights-job-workflow";
export { WorkoutSummaryJobWorkflow } from "./workout-summary-job-workflow";

const app = createApp();

export default {
  fetch(request: Request, env: unknown) {
    return app.fetch(request, env as import("./openai").Env);
  },
};
