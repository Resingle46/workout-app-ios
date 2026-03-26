declare module "cloudflare:workers" {
  export interface WorkflowEvent<TPayload = unknown> {
    payload: TPayload;
  }

  export interface WorkflowStep {
    do<T>(name: string, callback: () => Promise<T>): Promise<T>;
  }

  export abstract class WorkflowEntrypoint<TEnv = unknown, TPayload = unknown> {
    protected env: TEnv;

    constructor(ctx: unknown, env: TEnv);

    abstract run(
      event: WorkflowEvent<TPayload>,
      step: WorkflowStep
    ): Promise<unknown>;
  }
}
