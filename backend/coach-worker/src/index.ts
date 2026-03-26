import { createApp } from "./app";
export { CoachChatJobWorkflow } from "./chat-job-workflow";

const app = createApp();

export default {
  fetch(request: Request, env: unknown) {
    return app.fetch(request, env as import("./openai").Env);
  },
};
