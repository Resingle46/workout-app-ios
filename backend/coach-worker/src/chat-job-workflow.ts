import {
  WorkflowEntrypoint,
  type WorkflowEvent,
  type WorkflowStep,
} from "cloudflare:workers";
import { executeChatJob, type CoachChatWorkflowPayload } from "./chat-job-executor";
import type { Env } from "./openai";
import type { CoachChatJobRecord } from "./state";

export class CoachChatJobWorkflow extends WorkflowEntrypoint<
  Env,
  CoachChatWorkflowPayload
> {
  async run(
    event: WorkflowEvent<CoachChatWorkflowPayload>,
    step: WorkflowStep
  ): Promise<CoachChatJobRecord | null> {
    return executeChatJob(event.payload.jobID, this.env, {}, step);
  }
}
