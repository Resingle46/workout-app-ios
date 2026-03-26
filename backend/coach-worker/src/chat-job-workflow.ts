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
    const workflowInstanceID =
      "instanceId" in event && typeof event.instanceId === "string"
        ? event.instanceId
        : undefined;

    try {
      return await executeChatJob(event.payload.jobID, this.env, {}, step);
    } catch (error) {
      console.error(
        JSON.stringify({
          event: "coach_chat_workflow_run_failed",
          phase: "workflow_run",
          jobID: event.payload.jobID,
          workflowInstanceID,
          errorMessage:
            error instanceof Error ? error.message.slice(0, 300) : "Unknown error",
        })
      );
      throw error;
    }
  }
}
