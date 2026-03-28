import {
  WorkflowEntrypoint,
  type WorkflowEvent,
  type WorkflowStep,
} from "cloudflare:workers";
import {
  executeProfileInsightsJob,
  type ProfileInsightsWorkflowPayload,
} from "./profile-insights-job-executor";
import type { Env } from "./openai";

export class ProfileInsightsJobWorkflow extends WorkflowEntrypoint<
  Env,
  ProfileInsightsWorkflowPayload
> {
  async run(
    event: WorkflowEvent<ProfileInsightsWorkflowPayload>,
    step: WorkflowStep
  ): Promise<{ jobID: string; finalStatus?: string } | null> {
    const finalJob = await executeProfileInsightsJob(
      event.payload.jobID,
      this.env,
      {},
      step
    );
    return {
      jobID: event.payload.jobID,
      finalStatus: finalJob?.status,
    };
  }
}
