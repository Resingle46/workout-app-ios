import {
  WorkflowEntrypoint,
  type WorkflowEvent,
  type WorkflowStep,
} from "cloudflare:workers";
import {
  executeWorkoutSummaryJob,
  type WorkoutSummaryWorkflowPayload,
} from "./workout-summary-job-executor";
import type { Env } from "./openai";

export class WorkoutSummaryJobWorkflow extends WorkflowEntrypoint<
  Env,
  WorkoutSummaryWorkflowPayload
> {
  async run(
    event: WorkflowEvent<WorkoutSummaryWorkflowPayload>,
    step: WorkflowStep
  ): Promise<{ jobID: string; finalStatus?: string } | null> {
    const finalJob = await executeWorkoutSummaryJob(
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
