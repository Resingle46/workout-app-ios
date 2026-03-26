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
import type { CoachWorkoutSummaryJobRecord } from "./state";

export class WorkoutSummaryJobWorkflow extends WorkflowEntrypoint<
  Env,
  WorkoutSummaryWorkflowPayload
> {
  async run(
    event: WorkflowEvent<WorkoutSummaryWorkflowPayload>,
    step: WorkflowStep
  ): Promise<CoachWorkoutSummaryJobRecord | null> {
    return executeWorkoutSummaryJob(event.payload.jobID, this.env, {}, step);
  }
}
