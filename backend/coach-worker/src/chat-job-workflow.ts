import {
  WorkflowEntrypoint,
  type WorkflowEvent,
  type WorkflowStep,
} from "cloudflare:workers";
import { executeChatJob, type CoachChatWorkflowPayload } from "./chat-job-executor";
import type { Env } from "./openai";

export class CoachChatJobWorkflow extends WorkflowEntrypoint<
  Env,
  CoachChatWorkflowPayload
> {
  async run(
    event: WorkflowEvent<CoachChatWorkflowPayload>,
    step: WorkflowStep
  ): Promise<{ jobID: string; finalStatus?: string } | null> {
    const workflowInstanceID =
      "instanceId" in event && typeof event.instanceId === "string"
        ? event.instanceId
        : undefined;

    try {
      const finalJob = await executeChatJob(event.payload.jobID, this.env, {}, step);
      console.log(
        JSON.stringify({
          event: "coach_chat_workflow_run_completed",
          phase: "workflow_run",
          jobID: event.payload.jobID,
          workflowInstanceID,
          finalStatus: finalJob?.status,
          installID: finalJob?.installID,
          clientRequestID: finalJob?.clientRequestID,
          inferenceMode: finalJob?.inferenceMode,
          totalJobDurationMs: finalJob?.totalJobDurationMs,
        })
      );
      return {
        jobID: event.payload.jobID,
        finalStatus: finalJob?.status,
      };
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
