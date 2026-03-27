import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app";
import { executeChatJob } from "../src/chat-job-executor";
import * as chatJobExecutorModule from "../src/chat-job-executor";
import { CoachChatJobWorkflow } from "../src/chat-job-workflow";
import { executeWorkoutSummaryJob } from "../src/workout-summary-job-executor";
import {
  buildCoachContextFromSnapshot,
  hashCoachContext,
} from "../src/context";
import {
  CoachInferenceServiceError,
  DEFAULT_AI_MODEL,
  WorkersAICoachService,
  type CoachInferenceService,
  type Env,
} from "../src/openai";
import {
  InMemoryCoachStateRepository,
  storageKeyFromMetadata,
} from "../src/state";
import {
  buildProfileInsightsRoutingAttempts,
  buildProfileInsightsRoutingDecision,
  resolveModelForRole,
} from "../src/routing";
import type {
  AppSnapshotPayload,
  BackupUploadRequest,
  CoachChatJobCreateRequest,
  CoachChatRequest,
  CoachChatResponse,
  CoachProfileInsightsRequest,
  CoachProfileInsightsResponse,
  CoachWorkoutSummaryJobCreateRequest,
  CoachWorkoutSummaryJobStatusResponse,
  CoachWorkoutSummaryResponse,
  CompactCoachSnapshot,
} from "../src/schemas";

vi.mock("cloudflare:workers", () => ({
  WorkflowEntrypoint: class {
    protected env: unknown;

    constructor(_ctx: unknown, env: unknown) {
      this.env = env;
    }
  },
}));

describe("coach worker app", () => {
  it("returns health for configured runtime", async () => {
    const app = createApp({
      createInferenceService: () => {
        throw new Error("not used");
      },
    });

    const response = await app.fetch(
      new Request("https://coach.example.workers.dev/health"),
      makeEnv()
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      status: "ok",
      model: DEFAULT_AI_MODEL,
      promptVersion: "test.v1",
    });
  });

  it("rejects missing auth token", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });

    const response = await app.fetch(
      new Request("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        headers: {
          "content-type": "application/json",
        },
        body: JSON.stringify(makeProfileInsightsRequestFixture()),
      }),
      makeEnv()
    );

    expect(response.status).toBe(401);
    await expect(response.json()).resolves.toMatchObject({
      error: {
        code: "unauthorized",
      },
    });
  });

  it("stores legacy snapshot and reuses it on a follow-up insights request", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    let capturedSnapshot: CompactCoachSnapshot | undefined;
    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights(request) {
          capturedSnapshot = request.snapshot;
          return {
            data: {
              summary: "Remote summary",
              recommendations: ["Remote recommendation"],
              generationStatus: "model",
              insightSource: "fresh_model",
            },
            model: DEFAULT_AI_MODEL,
          };
        },
        async generateWorkoutSummary() {
          throw new Error("not used");
        },
        async generateChat() {
          throw new Error("not used");
        },
      }),
      createStateRepository: () => repository,
    });

    const legacySnapshot = makeCompactSnapshotFixture();
    const snapshotHash = await hashCoachContext(legacySnapshot);

    const syncResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/snapshot", {
        method: "PUT",
        body: JSON.stringify({
          installID: "install_legacy",
          snapshotHash,
          snapshot: legacySnapshot,
          snapshotUpdatedAt: "2026-03-25T19:00:00.000Z",
        }),
      }),
      makeEnv()
    );

    expect(syncResponse.status).toBe(200);

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        body: JSON.stringify({
          locale: "en",
          installID: "install_legacy",
          snapshotHash,
          capabilityScope: "draft_changes",
        }),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    expect(capturedSnapshot).toEqual(legacySnapshot);
  });

  it("uploads, reconciles, and downloads full backups", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const upload = makeBackupUploadRequestFixture();

    const initialReconcile = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup/reconcile", {
        method: "POST",
        body: JSON.stringify({
          installID: upload.installID,
          localBackupHash: "local-only-hash",
          localStateKind: "user_data",
        }),
      }),
      makeEnv()
    );
    await expect(initialReconcile.json()).resolves.toMatchObject({
      action: "upload",
    });

    const uploadResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        body: JSON.stringify(upload),
      }),
      makeEnv()
    );

    expect(uploadResponse.status).toBe(200);
    const uploaded = await uploadResponse.json();
    expect(uploaded.backupVersion).toBe(1);
    expect(uploaded.r2Key).toMatch(
      /^installs\/install_backup\/backups\/v000001-/
    );

    const noopReconcile = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup/reconcile", {
        method: "POST",
        body: JSON.stringify({
          installID: upload.installID,
          localBackupHash: uploaded.backupHash,
          localStateKind: "user_data",
          lastSyncedRemoteVersion: 1,
          lastSyncedBackupHash: uploaded.backupHash,
        }),
      }),
      makeEnv()
    );
    await expect(noopReconcile.json()).resolves.toMatchObject({
      action: "noop",
      remote: {
        backupVersion: 1,
      },
    });

    const downloadResponse = await app.fetch(
      authedRequest(
        `https://coach.example.workers.dev/v1/backup/download?installID=${upload.installID}&version=current`,
        {
          method: "GET",
        }
      ),
      makeEnv()
    );

    expect(downloadResponse.status).toBe(200);
    await expect(downloadResponse.json()).resolves.toMatchObject({
      remote: {
        backupVersion: 1,
        installID: upload.installID,
      },
      backup: {
        installID: upload.installID,
        snapshot: {
          profile: {
            weeklyWorkoutTarget: 4,
          },
        },
      },
    });
  });

  it("rejects stale backup uploads after the remote head moves", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });

    const firstUpload = makeBackupUploadRequestFixture();
    const secondUpload = makeBackupUploadRequestFixture();
    secondUpload.expectedRemoteVersion = 1;
    secondUpload.snapshot.profile.weeklyWorkoutTarget = 5;

    const staleUpload = makeBackupUploadRequestFixture();
    staleUpload.expectedRemoteVersion = 1;
    staleUpload.snapshot.profile.weeklyWorkoutTarget = 6;

    expect(
      (
        await app.fetch(
          authedRequest("https://coach.example.workers.dev/v1/backup", {
            method: "PUT",
            body: JSON.stringify(firstUpload),
          }),
          makeEnv()
        )
      ).status
    ).toBe(200);

    expect(
      (
        await app.fetch(
          authedRequest("https://coach.example.workers.dev/v1/backup", {
            method: "PUT",
            body: JSON.stringify(secondUpload),
          }),
          makeEnv()
        )
      ).status
    ).toBe(200);

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        body: JSON.stringify(staleUpload),
      }),
      makeEnv()
    );

    expect(response.status).toBe(409);
    await expect(response.json()).resolves.toMatchObject({
      error: {
        code: "remote_head_changed",
      },
    });
  });

  it("accepts backup uploads with legacy seed category IDs by normalizing to canonical IDs", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const upload = makeBackupUploadRequestFixture();
    upload.snapshot.exercises[0]!.categoryID =
      "A1000000-0000-0000-0000-000000000002";

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        body: JSON.stringify(upload),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    const downloadResponse = await app.fetch(
      authedRequest(
        `https://coach.example.workers.dev/v1/backup/download?installID=${upload.installID}&version=current`,
        {
          method: "GET",
        }
      ),
      makeEnv()
    );
    expect(downloadResponse.status).toBe(200);
    const stored = await downloadResponse.json();
    expect(stored.backup.snapshot.exercises[0]?.categoryID).toBe(
      "A1000000-0000-4000-8000-000000000002"
    );
  });

  it("uses server-side backup state plus coach preferences for slim insights requests", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    let capturedSnapshot: CompactCoachSnapshot | undefined;
    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights(request) {
          capturedSnapshot = request.snapshot;
          return {
            data: {
              summary: "Summary",
              recommendations: ["Recommendation"],
              generationStatus: "model",
              insightSource: "fresh_model",
            },
            model: DEFAULT_AI_MODEL,
          };
        },
        async generateWorkoutSummary() {
          throw new Error("not used");
        },
        async generateChat() {
          throw new Error("not used");
        },
      }),
      createStateRepository: () => repository,
    });

    const upload = makeBackupUploadRequestFixture();
    await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        body: JSON.stringify(upload),
      }),
      makeEnv()
    );

    const preferencesResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/preferences", {
        method: "PATCH",
        body: JSON.stringify({
          installID: upload.installID,
          selectedProgramID: upload.snapshot.programs[0]?.id,
          programComment: "I run this as a 3-day rotating split.",
        }),
      }),
      makeEnv()
    );

    expect(preferencesResponse.status).toBe(200);

    const insightsResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        body: JSON.stringify({
          locale: "en",
          installID: upload.installID,
          capabilityScope: "draft_changes",
        }),
      }),
      makeEnv()
    );

    expect(insightsResponse.status).toBe(200);
    expect(capturedSnapshot?.coachAnalysisSettings.programComment).toBe(
      "I run this as a 3-day rotating split."
    );
    expect(capturedSnapshot?.coachAnalysisSettings.selectedProgramID).toBe(
      upload.snapshot.programs[0]?.id
    );
  });

  it("skips cached fallback insights and refreshes them from the model", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const upload = makeBackupUploadRequestFixture();
    let inferenceCalls = 0;
    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
          inferenceCalls += 1;
          return {
            data: {
              summary: "Fresh remote summary",
              recommendations: ["Fresh remote recommendation"],
              generationStatus: "model",
              insightSource: "fresh_model",
            },
            model: DEFAULT_AI_MODEL,
          };
        },
        async generateWorkoutSummary() {
          throw new Error("not used");
        },
        async generateChat() {
          throw new Error("not used");
        },
      }),
      createStateRepository: () => repository,
    });

    await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        body: JSON.stringify(upload),
      }),
      makeEnv()
    );

    const context = await repository.resolveCoachContext({
      locale: "en",
      installID: upload.installID,
      capabilityScope: "draft_changes",
    });
    await repository.storeInsightsCache(
      upload.installID,
      storageKeyFromMetadata(context.contextHash, {
        contextProfile: "compact_sync_v2",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_compact_context_v2",
        memoryProfile: "compact_v1",
      }, "test.v1", DEFAULT_AI_MODEL),
      {
      summary: "Cached fallback summary",
      recommendations: ["Cached fallback recommendation"],
      generationStatus: "fallback",
      insightSource: "fallback",
      }
    );

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        body: JSON.stringify({
          locale: "en",
          installID: upload.installID,
          capabilityScope: "draft_changes",
        }),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    expect(inferenceCalls).toBe(1);
    await expect(response.json()).resolves.toMatchObject({
      summary: "Fresh remote summary",
      generationStatus: "model",
      insightSource: "fresh_model",
    });
  });

  it("marks cached model insights as cached without rerunning inference", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const upload = makeBackupUploadRequestFixture();
    let inferenceCalls = 0;
    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
          inferenceCalls += 1;
          return {
            data: {
              summary: "Fresh remote summary",
              recommendations: ["Fresh remote recommendation"],
              generationStatus: "model",
              insightSource: "fresh_model",
            },
            model: DEFAULT_AI_MODEL,
          };
        },
        async generateWorkoutSummary() {
          throw new Error("not used");
        },
        async generateChat() {
          throw new Error("not used");
        },
      }),
      createStateRepository: () => repository,
    });

    await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        body: JSON.stringify(upload),
      }),
      makeEnv()
    );

    const context = await repository.resolveCoachContext({
      locale: "en",
      installID: upload.installID,
      capabilityScope: "draft_changes",
    });
    await repository.storeInsightsCache(
      upload.installID,
      storageKeyFromMetadata(context.contextHash, {
        contextProfile: "compact_sync_v2",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_compact_context_v2",
        memoryProfile: "compact_v1",
      }, "test.v1", DEFAULT_AI_MODEL),
      {
      summary: "Cached remote summary",
      recommendations: ["Cached remote recommendation"],
      generationStatus: "model",
      insightSource: "fresh_model",
      }
    );

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        body: JSON.stringify({
          locale: "en",
          installID: upload.installID,
          capabilityScope: "draft_changes",
        }),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    expect(inferenceCalls).toBe(0);
    await expect(response.json()).resolves.toMatchObject({
      summary: "Cached remote summary",
      generationStatus: "model",
      insightSource: "cached_model",
    });
  });

  it("force refresh bypasses cache and replaces it with a fresh model insight", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const upload = makeBackupUploadRequestFixture();
    let inferenceCalls = 0;
    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
          inferenceCalls += 1;
          return {
            data: {
              summary: "Fresh remote summary",
              recommendations: ["Fresh remote recommendation"],
              generationStatus: "model",
              insightSource: "fresh_model",
            },
            model: DEFAULT_AI_MODEL,
          };
        },
        async generateWorkoutSummary() {
          throw new Error("not used");
        },
        async generateChat() {
          throw new Error("not used");
        },
      }),
      createStateRepository: () => repository,
    });

    await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        body: JSON.stringify(upload),
      }),
      makeEnv()
    );

    const context = await repository.resolveCoachContext({
      locale: "en",
      installID: upload.installID,
      capabilityScope: "draft_changes",
    });
    await repository.storeInsightsCache(
      upload.installID,
      storageKeyFromMetadata(context.contextHash, {
        contextProfile: "compact_sync_v2",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_compact_context_v2",
        memoryProfile: "compact_v1",
      }, "test.v1", DEFAULT_AI_MODEL),
      {
      summary: "Cached remote summary",
      recommendations: ["Cached remote recommendation"],
      generationStatus: "model",
      insightSource: "fresh_model",
      }
    );

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        body: JSON.stringify({
          locale: "en",
          installID: upload.installID,
          capabilityScope: "draft_changes",
          forceRefresh: true,
        }),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    expect(inferenceCalls).toBe(1);
    await expect(response.json()).resolves.toMatchObject({
      summary: "Fresh remote summary",
      generationStatus: "model",
      insightSource: "fresh_model",
    });
    await expect(
      repository.getInsightsCache(
        upload.installID,
        storageKeyFromMetadata(context.contextHash, {
          contextProfile: "compact_sync_v2",
          contextVersion: context.contextVersion,
          analyticsVersion: context.analyticsVersion,
          promptProfile: "profile_compact_context_v2",
          memoryProfile: "compact_v1",
        }, "test.v1", DEFAULT_AI_MODEL)
      )
    ).resolves.toMatchObject({
      summary: "Fresh remote summary",
      generationStatus: "model",
      insightSource: "fresh_model",
    });
  });

  it("reuses degraded profile insights sidecar responses on the next startup request", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    let inferenceCalls = 0;
    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
          inferenceCalls += 1;
          return {
            data: {
              summary: "Fallback sidecar summary",
              recommendations: ["Fallback sidecar recommendation"],
              generationStatus: "fallback",
              insightSource: "fallback",
            },
            model: DEFAULT_AI_MODEL,
            mode: "local_fallback",
          };
        },
        async generateWorkoutSummary() {
          throw new Error("not used");
        },
        async generateChat() {
          throw new Error("not used");
        },
      }),
      createStateRepository: () => repository,
    });
    const body = makeProfileInsightsRequestFixture();

    const firstResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        body: JSON.stringify(body),
      }),
      makeEnv()
    );
    const secondResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        body: JSON.stringify(body),
      }),
      makeEnv()
    );

    expect(firstResponse.status).toBe(200);
    expect(secondResponse.status).toBe(200);
    expect(inferenceCalls).toBe(1);
    await expect(secondResponse.json()).resolves.toMatchObject({
      summary: "Fallback sidecar summary",
      generationStatus: "fallback",
      insightSource: "fallback",
    });
  });

  it("prefers model cache over degraded sidecar cache for the same insights key", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const body = makeProfileInsightsRequestFixture();
    const context = await repository.resolveCoachContext(body);
    const key = storageKeyFromMetadata(
      context.contextHash,
      {
        contextProfile: "compact_sync_v2",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_compact_context_v2",
        memoryProfile: "compact_v1",
      },
      "test.v1",
      DEFAULT_AI_MODEL
    );
    await repository.storeInsightsCache(body.installID, key, {
      summary: "Cached model summary",
      recommendations: ["Cached model recommendation"],
      generationStatus: "model",
      insightSource: "fresh_model",
    });
    await repository.storeDegradedInsightsCache(body.installID, key, {
      summary: "Cached degraded summary",
      recommendations: ["Cached degraded recommendation"],
      generationStatus: "fallback",
      insightSource: "fallback",
    });

    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        body: JSON.stringify(body),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      summary: "Cached model summary",
      generationStatus: "model",
      insightSource: "cached_model",
    });
  });

  it("bypasses degraded sidecar cache on force refresh", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    let inferenceCalls = 0;
    const body = makeProfileInsightsRequestFixture();
    const context = await repository.resolveCoachContext(body);
    const key = storageKeyFromMetadata(
      context.contextHash,
      {
        contextProfile: "compact_sync_v2",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_compact_context_v2",
        memoryProfile: "compact_v1",
      },
      "test.v1",
      DEFAULT_AI_MODEL
    );
    await repository.storeDegradedInsightsCache(body.installID, key, {
      summary: "Cached degraded summary",
      recommendations: ["Cached degraded recommendation"],
      generationStatus: "fallback",
      insightSource: "fallback",
    });

    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
          inferenceCalls += 1;
          return {
            data: {
              summary: "Force refreshed summary",
              recommendations: ["Force refreshed recommendation"],
              generationStatus: "model",
              insightSource: "fresh_model",
            },
            model: DEFAULT_AI_MODEL,
            mode: "structured",
          };
        },
        async generateWorkoutSummary() {
          throw new Error("not used");
        },
        async generateChat() {
          throw new Error("not used");
        },
      }),
      createStateRepository: () => repository,
    });

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        body: JSON.stringify({
          ...body,
          forceRefresh: true,
        }),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    expect(inferenceCalls).toBe(1);
    await expect(response.json()).resolves.toMatchObject({
      summary: "Force refreshed summary",
      generationStatus: "model",
      insightSource: "fresh_model",
    });
  });

  it("does not reuse degraded sidecar cache after the insights fingerprint changes", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    let inferenceCalls = 0;
    const originalBody = makeProfileInsightsRequestFixture();
    const originalContext = await repository.resolveCoachContext(originalBody);
    const originalKey = storageKeyFromMetadata(
      originalContext.contextHash,
      {
        contextProfile: "compact_sync_v2",
        contextVersion: originalContext.contextVersion,
        analyticsVersion: originalContext.analyticsVersion,
        promptProfile: "profile_compact_context_v2",
        memoryProfile: "compact_v1",
      },
      "test.v1",
      DEFAULT_AI_MODEL
    );
    await repository.storeDegradedInsightsCache(originalBody.installID, originalKey, {
      summary: "Old degraded summary",
      recommendations: ["Old degraded recommendation"],
      generationStatus: "fallback",
      insightSource: "fallback",
    });

    const changedBody = makeProfileInsightsRequestFixture();
    const changedSnapshot = changedBody.snapshot!;
    changedBody.snapshotHash = "different-snapshot-hash";
    changedBody.snapshot = {
      ...changedSnapshot,
      analytics: {
        ...changedSnapshot.analytics,
        consistency: {
          ...changedSnapshot.analytics.consistency,
          workoutsThisWeek: changedSnapshot.analytics.consistency.workoutsThisWeek + 1,
        },
      },
    };

    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
          inferenceCalls += 1;
          return {
            data: {
              summary: "Fresh after fingerprint change",
              recommendations: ["Fresh recommendation"],
              generationStatus: "model",
              insightSource: "fresh_model",
            },
            model: DEFAULT_AI_MODEL,
            mode: "structured",
          };
        },
        async generateWorkoutSummary() {
          throw new Error("not used");
        },
        async generateChat() {
          throw new Error("not used");
        },
      }),
      createStateRepository: () => repository,
    });

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        body: JSON.stringify(changedBody),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    expect(inferenceCalls).toBe(1);
    await expect(response.json()).resolves.toMatchObject({
      summary: "Fresh after fingerprint change",
      generationStatus: "model",
      insightSource: "fresh_model",
    });
  });

  it("clears only the matching degraded sidecar entry after a successful model refresh", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const body = makeProfileInsightsRequestFixture();
    const context = await repository.resolveCoachContext(body);
    const matchingKey = storageKeyFromMetadata(
      context.contextHash,
      {
        contextProfile: "compact_sync_v2",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_compact_context_v2",
        memoryProfile: "compact_v1",
      },
      "test.v1",
      DEFAULT_AI_MODEL
    );
    const otherKey = {
      ...matchingKey,
      contextHash: "ctx_hash_other",
    };
    await repository.storeDegradedInsightsCache(body.installID, matchingKey, {
      summary: "Matching degraded summary",
      recommendations: ["Matching degraded recommendation"],
      generationStatus: "fallback",
      insightSource: "fallback",
    });
    await repository.storeDegradedInsightsCache(body.installID, otherKey, {
      summary: "Other degraded summary",
      recommendations: ["Other degraded recommendation"],
      generationStatus: "fallback",
      insightSource: "fallback",
    });

    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
          return {
            data: {
              summary: "Fresh structured summary",
              recommendations: ["Fresh structured recommendation"],
              generationStatus: "model",
              insightSource: "fresh_model",
            },
            model: DEFAULT_AI_MODEL,
            mode: "structured",
          };
        },
        async generateWorkoutSummary() {
          throw new Error("not used");
        },
        async generateChat() {
          throw new Error("not used");
        },
      }),
      createStateRepository: () => repository,
    });

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        body: JSON.stringify({
          ...body,
          forceRefresh: true,
        }),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    await expect(
      repository.getDegradedInsightsCache(body.installID, matchingKey)
    ).resolves.toBeNull();
    await expect(
      repository.getDegradedInsightsCache(body.installID, otherKey)
    ).resolves.toMatchObject({
      summary: "Other degraded summary",
      generationStatus: "fallback",
    });
  });

  it("stores live fallback results only in the degraded sidecar cache", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const body = makeProfileInsightsRequestFixture();
    const context = await repository.resolveCoachContext(body);
    const key = storageKeyFromMetadata(
      context.contextHash,
      {
        contextProfile: "compact_sync_v2",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_compact_context_v2",
        memoryProfile: "compact_v1",
      },
      "test.v1",
      DEFAULT_AI_MODEL
    );
    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
          return {
            data: {
              summary: "Local fallback summary",
              recommendations: ["Local fallback recommendation"],
              generationStatus: "fallback",
              insightSource: "fallback",
            },
            model: DEFAULT_AI_MODEL,
            mode: "local_fallback",
          };
        },
        async generateWorkoutSummary() {
          throw new Error("not used");
        },
        async generateChat() {
          throw new Error("not used");
        },
      }),
      createStateRepository: () => repository,
    });

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        body: JSON.stringify(body),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    await expect(
      repository.getInsightsCache(body.installID, key)
    ).resolves.toBeNull();
    await expect(
      repository.getDegradedInsightsCache(body.installID, key)
    ).resolves.toMatchObject({
      summary: "Local fallback summary",
      generationStatus: "fallback",
      insightSource: "fallback",
    });
  });

  it("does not mark rolling rotation as program frequency mismatch", () => {
    const snapshot = makeAppSnapshotFixture();
    snapshot.profile.weeklyWorkoutTarget = 3;
    snapshot.programs[0]!.workouts = [
      snapshot.programs[0]!.workouts[0]!,
      {
        ...snapshot.programs[0]!.workouts[0]!,
        id: "22222222-2222-4222-8222-222222222223",
        title: "Lower A",
        focus: "Quads and hamstrings",
      },
      {
        ...snapshot.programs[0]!.workouts[0]!,
        id: "22222222-2222-4222-8222-222222222224",
        title: "Upper B",
        focus: "Back and shoulders",
      },
      {
        ...snapshot.programs[0]!.workouts[0]!,
        id: "22222222-2222-4222-8222-222222222225",
        title: "Lower B",
        focus: "Glutes and calves",
      },
    ];

    const compactSnapshot = buildCoachContextFromSnapshot({
      snapshot,
    });

    expect(
      compactSnapshot.analytics.compatibility.issues.some(
        (issue) => issue.kind === "program_frequency_mismatch"
      )
    ).toBe(false);
    expect(compactSnapshot.analytics.derivedAnalytics?.splitExecution.mode).toBe(
      "rolling_rotation"
    );
  });

  it("uses server-side context for slim chat requests", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    let capturedRequest: CoachChatRequest | undefined;
    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
          throw new Error("not used");
        },
        async generateWorkoutSummary() {
          throw new Error("not used");
        },
        async generateChat(request) {
          capturedRequest = request;
          return {
            data: {
              answerMarkdown: "Coach answer",
              responseID: "coach-turn_1",
              followUps: ["Need a progression block?"],
              generationStatus: "model",
            },
            responseId: "coach-turn_1",
            model: DEFAULT_AI_MODEL,
          };
        },
      }),
      createStateRepository: () => repository,
    });

    const upload = makeBackupUploadRequestFixture();
    await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        body: JSON.stringify(upload),
      }),
      makeEnv()
    );

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/chat", {
        method: "POST",
        body: JSON.stringify({
          locale: "en",
          installID: upload.installID,
          question: "How should I progress next week?",
          clientRecentTurns: [
            {
              role: "user",
              content: "My top sets felt heavy last week.",
            },
          ],
          capabilityScope: "draft_changes",
        }),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    expect(capturedRequest?.snapshot?.profile.weeklyWorkoutTarget).toBe(4);
    expect(capturedRequest?.snapshot).toBeTruthy();
  });

  it("returns a chat answer instead of 504 when timeout fallback succeeds", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const aiRun = vi
      .fn()
      .mockRejectedValueOnce(new Error("Request timed out"))
      .mockResolvedValueOnce({
        response: "Keep load the same next week and add one rep where bar speed stays solid.",
      });
    const app = createApp({
      createStateRepository: () => repository,
    });
    const env = makeEnv({
      AI: {
        run: aiRun,
      },
    });
    const upload = makeBackupUploadRequestFixture();

    await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        body: JSON.stringify(upload),
      }),
      env
    );

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/chat", {
        method: "POST",
        body: JSON.stringify({
          locale: "en",
          installID: upload.installID,
          question: "How should I progress next week?",
          clientRecentTurns: [],
          capabilityScope: "draft_changes",
        }),
      }),
      env
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      answerMarkdown:
        "Keep load the same next week and add one rep where bar speed stays solid.",
      followUps: [],
      generationStatus: "model",
    });
  });

  it("creates a queued async chat job and starts the workflow", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const env = makeEnv({
      COACH_CHAT_WORKFLOW: makeWorkflowBinding(workflowCreate),
    });
    const request = makeChatJobCreateRequestFixture();

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(request),
      }),
      env
    );

    expect(response.status).toBe(202);
    const body = await response.json();
    expect(body).toMatchObject({
      status: "queued",
      pollAfterMs: 1500,
      metadata: {
        contextProfile: "rich_async_v1",
        promptProfile: "chat_rich_async_v1",
        memoryProfile: "rich_async_v1",
      },
    });
    expect(body.jobID).toMatch(/^coach-job_/);
    expect(workflowCreate).toHaveBeenCalledTimes(1);

    const storedJob = await repository.getChatJob(body.jobID, request.installID);
    expect(storedJob?.preparedRequest.clientRequestID).toBe(request.clientRequestID);
    expect(storedJob?.preparedRequest.responseID).toMatch(/^coach-turn_/);
    expect(storedJob?.preparedRequest.metadata).toMatchObject({
      contextProfile: "rich_async_v1",
      promptProfile: "chat_rich_async_v1",
      memoryProfile: "rich_async_v1",
    });
  });

  it("creates an async chat job with no recent turns", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const env = makeEnv({
      COACH_CHAT_WORKFLOW: makeWorkflowBinding(workflowCreate),
    });
    const request = {
      ...makeChatJobCreateRequestFixture(),
      clientRecentTurns: [],
    };

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(request),
      }),
      env
    );

    expect(response.status).toBe(202);
    const created = await response.json();
    const storedJob = await repository.getChatJob(created.jobID, request.installID);
    expect(storedJob?.preparedRequest.clientRecentTurns).toEqual([]);
    expect(workflowCreate).toHaveBeenCalledTimes(1);
  });

  it("creates an async follow-up chat job with populated recent turns", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const env = makeEnv({
      COACH_CHAT_WORKFLOW: makeWorkflowBinding(workflowCreate),
    });
    const request = {
      ...makeChatJobCreateRequestFixture(),
      clientRecentTurns: [
        {
          role: "user" as const,
          content: "Can you help me plan the next progression step?",
        },
        {
          role: "assistant" as const,
          content: "A".repeat(1_800),
        },
      ],
    };

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(request),
      }),
      env
    );

    expect(response.status).toBe(202);
    const created = await response.json();
    const storedJob = await repository.getChatJob(created.jobID, request.installID);
    expect(storedJob?.preparedRequest.clientRecentTurns).toEqual([
      {
        role: "user",
        content: "Can you help me plan the next progression step?",
      },
      {
        role: "assistant",
        content: "A".repeat(800),
      },
    ]);
  });

  it("rejects malformed async chat recent turns and logs the failing schema path", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const request = {
      ...makeChatJobCreateRequestFixture(),
      clientRecentTurns: [
        {
          role: "assistant",
          content: { markdown: "not a string" },
        },
      ],
    };

    try {
      const response = await app.fetch(
        authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
          method: "POST",
          body: JSON.stringify(request),
        }),
        makeEnv()
      );

      expect(response.status).toBe(400);
      await expect(response.json()).resolves.toMatchObject({
        error: {
          code: "invalid_request",
        },
      });
      expect(warnSpy).toHaveBeenCalledTimes(1);
      expect(errorSpy).not.toHaveBeenCalled();
      expect(logSpy).not.toHaveBeenCalled();

      const logged = parseLoggedPayload(warnSpy);
      expect(logged).toMatchObject({
        route: "/v2/coach/chat-jobs",
        method: "POST",
        status: 400,
        errorCode: "invalid_request",
        errorDetails: {
          requestPreview: {
            clientRecentTurnsCount: 1,
            clientRecentTurns: [
              {
                index: 0,
                role: "assistant",
                contentType: "object",
              },
            ],
          },
        },
        validationIssues: expect.arrayContaining([
          expect.objectContaining({
            code: "invalid_type",
            path: ["clientRecentTurns", 0, "content"],
            expected: "string",
            received: "object",
          }),
        ]),
      });
    } finally {
      warnSpy.mockRestore();
      errorSpy.mockRestore();
      logSpy.mockRestore();
    }
  });

  it("returns the existing async chat job for duplicate clientRequestID", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const env = makeEnv({
      COACH_CHAT_WORKFLOW: makeWorkflowBinding(workflowCreate),
    });
    const request = makeChatJobCreateRequestFixture();

    const firstResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(request),
      }),
      env
    );
    const secondResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(request),
      }),
      env
    );

    expect(firstResponse.status).toBe(202);
    expect(secondResponse.status).toBe(202);

    const firstBody = await firstResponse.json();
    const secondBody = await secondResponse.json();
    expect(secondBody.jobID).toBe(firstBody.jobID);
    expect(workflowCreate).toHaveBeenCalledTimes(1);
  });

  it("rejects a second async chat job while one is already active", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const env = makeEnv({
      COACH_CHAT_WORKFLOW: makeWorkflowBinding(workflowCreate),
    });
    const firstRequest = makeChatJobCreateRequestFixture();
    const secondRequest = {
      ...makeChatJobCreateRequestFixture(),
      clientRequestID: crypto.randomUUID(),
    };

    const firstResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(firstRequest),
      }),
      env
    );
    const firstBody = await firstResponse.json();

    const secondResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(secondRequest),
      }),
      env
    );

    expect(secondResponse.status).toBe(409);
    await expect(secondResponse.json()).resolves.toMatchObject({
      error: {
        code: "chat_job_in_progress",
      },
      jobID: firstBody.jobID,
    });
  });

  it("completes an async chat job and commits chat memory once", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createStateRepository: () => repository,
      createInferenceService: () =>
        stubInferenceService({
          chat: {
            answerMarkdown: "Async coach answer",
            responseID: "unused",
            followUps: ["Need a deload option?"],
            generationStatus: "model",
          },
        }),
    });
    const env = makeEnv({
      COACH_CHAT_WORKFLOW: makeWorkflowBinding(workflowCreate),
    });
    const createRequest = makeChatJobCreateRequestFixture();

    const createResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(createRequest),
      }),
      env
    );
    const created = await createResponse.json();

    await executeChatJob(created.jobID, env, {
      createStateRepository: () => repository,
      createInferenceService: () =>
        stubInferenceService({
          chat: {
            answerMarkdown: "Async coach answer",
            responseID: "unused",
            followUps: ["Need a deload option?"],
            generationStatus: "model",
          },
        }),
    });

    const statusResponse = await app.fetch(
      authedRequest(
        `https://coach.example.workers.dev/v2/coach/chat-jobs/${created.jobID}?installID=${createRequest.installID}`,
        {
          method: "GET",
        }
      ),
      env
    );

    expect(statusResponse.status).toBe(200);
    await expect(statusResponse.json()).resolves.toMatchObject({
      jobID: created.jobID,
      status: "completed",
      result: {
        answerMarkdown: "Async coach answer",
        generationStatus: "model",
        inferenceMode: "structured",
      },
    });

    const storedJob = await repository.getChatJob(created.jobID, createRequest.installID);
    const memory = storedJob
      ? await repository.getChatMemory(
          storedJob.installID,
          storageKeyFromMetadata(
            storedJob.contextHash,
            storedJob.preparedRequest.metadata,
            storedJob.promptVersion,
            storedJob.model
          )
        )
      : null;

    expect(memory?.recentTurns.at(-2)).toMatchObject({
      role: "user",
      content: createRequest.question,
    });
    expect(memory?.recentTurns.at(-1)).toMatchObject({
      role: "assistant",
      content: "Async coach answer",
    });

    await repository.commitChatJobMemory(created.jobID);
    const committedAgain = storedJob
      ? await repository.getChatMemory(
          storedJob.installID,
          storageKeyFromMetadata(
            storedJob.contextHash,
            storedJob.preparedRequest.metadata,
            storedJob.promptVersion,
            storedJob.model
          )
        )
      : null;
    expect(committedAgain).toEqual(memory);
  });

  it("keeps an async chat job completed when chat memory commit fails", async () => {
    class FailingCommitRepository extends InMemoryCoachStateRepository {
      override async commitChatJobMemory(): Promise<void> {
        throw new Error("KV temporarily unavailable");
      }
    }

    const repository = new FailingCommitRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createStateRepository: () => repository,
      createInferenceService: () =>
        stubInferenceService({
          chat: {
            answerMarkdown: "Async coach answer",
            responseID: "unused",
            followUps: ["Need a deload option?"],
            generationStatus: "model",
          },
        }),
    });
    const env = makeEnv({
      COACH_CHAT_WORKFLOW: makeWorkflowBinding(workflowCreate),
    });
    const createRequest = makeChatJobCreateRequestFixture();

    const createResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(createRequest),
      }),
      env
    );
    const created = await createResponse.json();

    const completed = await executeChatJob(created.jobID, env, {
      createStateRepository: () => repository,
      createInferenceService: () =>
        stubInferenceService({
          chat: {
            answerMarkdown: "Async coach answer",
            responseID: "unused",
            followUps: ["Need a deload option?"],
            generationStatus: "model",
          },
        }),
    });

    expect(completed?.status).toBe("completed");
    expect(completed?.result?.answerMarkdown).toBe("Async coach answer");
    expect(completed?.memoryCommittedAt).toBeUndefined();

    const storedJob = await repository.getChatJob(created.jobID, createRequest.installID);
    expect(storedJob?.status).toBe("completed");
    expect(storedJob?.error).toBeUndefined();
  });

  it("logs workflow run completion with safe correlation fields on normal return", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const env = makeEnv();
    const workflow = new CoachChatJobWorkflow({}, env);
    const returnedJob = {
      jobID: "job_diag_001",
      installID: "install_diag_001",
      clientRequestID: "client_request_diag_001",
      status: "completed" as const,
      preparedRequest: {
        ...makeChatRequestFixture(),
        clientRequestID: "client_request_diag_001",
        responseID: "coach-turn_diag_001",
      },
      result: {
        answerMarkdown: "Sensitive coach answer that must not reach workflow logs.",
        responseID: "coach-turn_diag_001",
        followUps: ["Sensitive follow-up"],
        generationStatus: "model" as const,
        inferenceMode: "structured" as const,
        totalJobDurationMs: 987,
      },
      createdAt: "2026-03-26T19:00:00.000Z",
      completedAt: "2026-03-26T19:00:10.000Z",
      contextHash: "context_hash_diag_001",
      contextSource: "remote_full" as const,
      chatMemoryHit: false,
      snapshotBytes: 2048,
      recentTurnCount: 2,
      recentTurnChars: 88,
      questionChars: 41,
      promptVersion: "test.v1",
      model: DEFAULT_AI_MODEL,
      totalJobDurationMs: 987,
      inferenceMode: "structured" as const,
      generationStatus: "model" as const,
    };
    const executeSpy = vi
      .spyOn(chatJobExecutorModule, "executeChatJob")
      .mockResolvedValue(returnedJob);
    const event = {
      payload: { jobID: returnedJob.jobID },
      instanceId: "workflow-instance-diag-001",
    } as Parameters<CoachChatJobWorkflow["run"]>[0];
    const step = {
      do: vi.fn(async (_name: string, callback: () => Promise<unknown>) => callback()),
    } as Parameters<CoachChatJobWorkflow["run"]>[1];

    try {
      const result = await workflow.run(event, step);

      expect(result).toEqual({
        jobID: returnedJob.jobID,
        finalStatus: returnedJob.status,
      });
      expect(executeSpy).toHaveBeenCalledWith(returnedJob.jobID, env, {}, step);
      expect(errorSpy).not.toHaveBeenCalled();
      expect(logSpy).toHaveBeenCalledTimes(1);

      const logged = parseLoggedPayload(logSpy);
      expect(logged).toMatchObject({
        event: "coach_chat_workflow_run_completed",
        phase: "workflow_run",
        jobID: returnedJob.jobID,
        workflowInstanceID: "workflow-instance-diag-001",
        finalStatus: "completed",
        installID: returnedJob.installID,
        clientRequestID: returnedJob.clientRequestID,
        inferenceMode: "structured",
        totalJobDurationMs: 987,
      });
      expect(logged).not.toHaveProperty("preparedRequest");
      expect(logged).not.toHaveProperty("result");
      expect(logged).not.toHaveProperty("snapshot");
      const loggedText = JSON.stringify(logged);
      expect(loggedText).not.toContain(returnedJob.preparedRequest.question);
      expect(loggedText).not.toContain(
        returnedJob.preparedRequest.clientRecentTurns[0]!.content
      );
      expect(loggedText).not.toContain(returnedJob.result.answerMarkdown);
      expect(loggedText).not.toContain("Upper A");
    } finally {
      executeSpy.mockRestore();
      logSpy.mockRestore();
      errorSpy.mockRestore();
    }
  });

  it("does not execute the same async chat job twice", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const inferenceService = stubInferenceService({
      chat: {
        answerMarkdown: "Async coach answer",
        responseID: "unused",
        followUps: ["Need a deload option?"],
        generationStatus: "model",
      },
    });
    const generateChatSpy = vi.spyOn(inferenceService, "generateChat");
    const app = createApp({
      createStateRepository: () => repository,
      createInferenceService: () => inferenceService,
    });
    const env = makeEnv({
      COACH_CHAT_WORKFLOW: makeWorkflowBinding(workflowCreate),
    });
    const createRequest = makeChatJobCreateRequestFixture();

    const createResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(createRequest),
      }),
      env
    );
    const created = await createResponse.json();

    await Promise.all([
      executeChatJob(created.jobID, env, {
        createStateRepository: () => repository,
        createInferenceService: () => inferenceService,
      }),
      executeChatJob(created.jobID, env, {
        createStateRepository: () => repository,
        createInferenceService: () => inferenceService,
      }),
    ]);

    expect(generateChatSpy).toHaveBeenCalledTimes(1);

    const storedJob = await repository.getChatJob(created.jobID, createRequest.installID);
    expect(storedJob?.status).toBe("completed");
    expect(storedJob?.result?.answerMarkdown).toBe("Async coach answer");
  });

  it("marks an async chat job failed and leaves chat memory untouched", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const env = makeEnv({
      COACH_CHAT_WORKFLOW: makeWorkflowBinding(workflowCreate),
    });
    const createRequest = makeChatJobCreateRequestFixture();

    const createResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(createRequest),
      }),
      env
    );
    const created = await createResponse.json();

    await executeChatJob(created.jobID, env, {
      createStateRepository: () => repository,
      createInferenceService: () =>
        stubInferenceService({
          chatError: new CoachInferenceServiceError(
            504,
            "upstream_timeout",
            "Workers AI request timed out",
            {
              promptBytes: 321,
              mode: "structured",
              modelDurationMs: 5_000,
            }
          ),
        }),
    });

    const statusResponse = await app.fetch(
      authedRequest(
        `https://coach.example.workers.dev/v2/coach/chat-jobs/${created.jobID}?installID=${createRequest.installID}`,
        {
          method: "GET",
        }
      ),
      env
    );

    expect(statusResponse.status).toBe(200);
    await expect(statusResponse.json()).resolves.toMatchObject({
      jobID: created.jobID,
      status: "failed",
      error: {
        code: "upstream_timeout",
      },
    });

    const storedJob = await repository.getChatJob(created.jobID, createRequest.installID);
    const memory = storedJob
      ? await repository.getChatMemory(
          storedJob.installID,
          storageKeyFromMetadata(
            storedJob.contextHash,
            storedJob.preparedRequest.metadata,
            storedJob.promptVersion,
            storedJob.model
          )
        )
      : null;
    expect(memory).toBeNull();
  });

  it("keeps failing chat jobs terminal even when fail-state persistence fails once", async () => {
    class FailOncePersistRepository extends InMemoryCoachStateRepository {
      private hasFailedPersist = false;

      override async failChatJob(
        ...args: Parameters<InMemoryCoachStateRepository["failChatJob"]>
      ): ReturnType<InMemoryCoachStateRepository["failChatJob"]> {
        if (!this.hasFailedPersist) {
          this.hasFailedPersist = true;
          throw new Error("D1 transient write failure");
        }
        return super.failChatJob(...args);
      }
    }

    const repository = new FailOncePersistRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const env = makeEnv({
      COACH_CHAT_WORKFLOW: makeWorkflowBinding(workflowCreate),
    });
    const createRequest = makeChatJobCreateRequestFixture();

    const createResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(createRequest),
      }),
      env
    );
    const created = await createResponse.json();

    const failed = await executeChatJob(created.jobID, env, {
      createStateRepository: () => repository,
      createInferenceService: () =>
        stubInferenceService({
          chatError: new CoachInferenceServiceError(
            504,
            "upstream_timeout",
            "Workers AI request timed out"
          ),
        }),
    });

    expect(failed?.status).toBe("failed");
    expect(failed?.error?.code).toBe("upstream_timeout");

    const storedJob = await repository.getChatJob(created.jobID, createRequest.installID);
    expect(storedJob?.status).toBe("failed");
    expect(storedJob?.error?.code).toBe("upstream_timeout");
  });

  it("creates a queued workout summary job and starts the workflow", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const env = makeEnv({
      WORKOUT_SUMMARY_WORKFLOW: makeWorkflowBinding(workflowCreate),
    });
    const request = makeWorkoutSummaryJobCreateRequestFixture();

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/workout-summary-jobs", {
        method: "POST",
        body: JSON.stringify(request),
      }),
      env
    );

    expect(response.status).toBe(202);
    await expect(response.json()).resolves.toMatchObject({
      sessionID: request.sessionID,
      fingerprint: request.fingerprint,
      status: "queued",
      pollAfterMs: 1500,
      reusedExistingJob: false,
      metadata: {
        contextProfile: "rich_async_v1",
        promptProfile: "workout_summary_rich_async_v1",
        memoryProfile: "rich_async_v1",
      },
    });
    expect(workflowCreate).toHaveBeenCalledTimes(1);
  });

  it("reuses an existing workout summary job for the same fingerprint", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const env = makeEnv({
      WORKOUT_SUMMARY_WORKFLOW: makeWorkflowBinding(workflowCreate),
    });
    const request = makeWorkoutSummaryJobCreateRequestFixture();

    const firstResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/workout-summary-jobs", {
        method: "POST",
        body: JSON.stringify(request),
      }),
      env
    );
    const firstBody = await firstResponse.json();

    const secondRequest = {
      ...makeWorkoutSummaryJobCreateRequestFixture(),
      sessionID: request.sessionID,
      fingerprint: request.fingerprint,
      currentWorkout: request.currentWorkout,
      recentExerciseHistory: request.recentExerciseHistory,
      requestMode: "final" as const,
      trigger: "final_after_finish" as const,
      inputMode: "finished_session" as const,
    };

    const secondResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/workout-summary-jobs", {
        method: "POST",
        body: JSON.stringify(secondRequest),
      }),
      env
    );

    expect(secondResponse.status).toBe(202);
    await expect(secondResponse.json()).resolves.toMatchObject({
      jobID: firstBody.jobID,
      reusedExistingJob: true,
    });
    expect(workflowCreate).toHaveBeenCalledTimes(1);
  });

  it("creates a new workout summary job after a failed fingerprint match", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const env = makeEnv({
      WORKOUT_SUMMARY_WORKFLOW: makeWorkflowBinding(workflowCreate),
    });
    const request = makeWorkoutSummaryJobCreateRequestFixture();

    const firstResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/workout-summary-jobs", {
        method: "POST",
        body: JSON.stringify(request),
      }),
      env
    );
    const firstBody = (await firstResponse.json()) as {
      jobID: string;
    };

    await repository.failWorkoutSummaryJob(firstBody.jobID, {
      completedAt: new Date().toISOString(),
      error: {
        code: "upstream_timeout",
        message: "Workout summary inference timed out.",
        retryable: true,
      },
      totalJobDurationMs: 500,
    });

    const retryRequest = {
      ...makeWorkoutSummaryJobCreateRequestFixture(),
      sessionID: request.sessionID,
      fingerprint: request.fingerprint,
      currentWorkout: request.currentWorkout,
      recentExerciseHistory: request.recentExerciseHistory,
      requestMode: "final" as const,
      trigger: "final_after_finish" as const,
      inputMode: "finished_session" as const,
    };

    const retryResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/workout-summary-jobs", {
        method: "POST",
        body: JSON.stringify(retryRequest),
      }),
      env
    );
    const retryBody = (await retryResponse.json()) as {
      jobID: string;
      reusedExistingJob: boolean;
    };

    expect(retryResponse.status).toBe(202);
    expect(retryBody.jobID).not.toBe(firstBody.jobID);
    expect(retryBody.reusedExistingJob).toBe(false);
    expect(workflowCreate).toHaveBeenCalledTimes(2);
  });

  it("completes a workout summary job and serves the result", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createStateRepository: () => repository,
      createInferenceService: () =>
        stubInferenceService({
          workoutSummary: {
            headline: "Bench volume held up",
            summary: "You finished the main work with stable loading across all completed sets.",
            highlights: ["Bench matched your best recent load."],
            nextWorkoutFocus: ["Add load only if bar speed stays clean again."],
            generationStatus: "model",
          },
        }),
    });
    const env = makeEnv({
      WORKOUT_SUMMARY_WORKFLOW: makeWorkflowBinding(workflowCreate),
    });
    const request = makeWorkoutSummaryJobCreateRequestFixture();

    const createResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/workout-summary-jobs", {
        method: "POST",
        body: JSON.stringify(request),
      }),
      env
    );
    const created = await createResponse.json();

    await executeWorkoutSummaryJob(created.jobID, env, {
      createStateRepository: () => repository,
      createInferenceService: () =>
        stubInferenceService({
          workoutSummary: {
            headline: "Bench volume held up",
            summary: "You finished the main work with stable loading across all completed sets.",
            highlights: ["Bench matched your best recent load."],
            nextWorkoutFocus: ["Add load only if bar speed stays clean again."],
            generationStatus: "model",
          },
        }),
    });

    const statusResponse = await app.fetch(
      authedRequest(
        `https://coach.example.workers.dev/v2/coach/workout-summary-jobs/${created.jobID}?installID=${request.installID}`,
        { method: "GET" }
      ),
      env
    );

    expect(statusResponse.status).toBe(200);
    await expect(statusResponse.json()).resolves.toMatchObject({
      jobID: created.jobID,
      sessionID: request.sessionID,
      fingerprint: request.fingerprint,
      status: "completed",
      result: {
        headline: "Bench volume held up",
        inferenceMode: "structured",
        generationStatus: "model",
      },
    });
  });

  it("allows a workout summary job while a chat job is already active", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const chatWorkflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const summaryWorkflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const env = makeEnv({
      COACH_CHAT_WORKFLOW: makeWorkflowBinding(chatWorkflowCreate),
      WORKOUT_SUMMARY_WORKFLOW: makeWorkflowBinding(summaryWorkflowCreate),
    });

    const chatResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(makeChatJobCreateRequestFixture()),
      }),
      env
    );
    expect(chatResponse.status).toBe(202);

    const summaryResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/workout-summary-jobs", {
        method: "POST",
        body: JSON.stringify(makeWorkoutSummaryJobCreateRequestFixture()),
      }),
      env
    );

    expect(summaryResponse.status).toBe(202);
    expect(summaryWorkflowCreate).toHaveBeenCalledTimes(1);
  });

  it("deletes stored state for an install ID", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const upload = makeBackupUploadRequestFixture();

    await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        body: JSON.stringify(upload),
      }),
      makeEnv()
    );

    const deleteResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/state", {
        method: "DELETE",
        body: JSON.stringify({
          installID: upload.installID,
        }),
      }),
      makeEnv()
    );

    expect(deleteResponse.status).toBe(200);

    const downloadResponse = await app.fetch(
      authedRequest(
        `https://coach.example.workers.dev/v1/backup/download?installID=${upload.installID}`,
        {
          method: "GET",
        }
      ),
      makeEnv()
    );

    expect(downloadResponse.status).toBe(404);
  });

  it("returns 400 for invalid backup uploads and logs safe validation details at warn level", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const invalidUpload = {
      ...makeBackupUploadRequestFixture(),
      appVersion: 42,
      buildNumber: 100,
    };

    try {
      const response = await app.fetch(
        authedRequest("https://coach.example.workers.dev/v1/backup", {
          method: "PUT",
          body: JSON.stringify(invalidUpload),
        }),
        makeEnv()
      );

      expect(response.status).toBe(400);
      await expect(response.json()).resolves.toMatchObject({
        error: {
          code: "invalid_request",
        },
      });
      expect(warnSpy).toHaveBeenCalledTimes(1);
      expect(errorSpy).not.toHaveBeenCalled();
      expect(logSpy).not.toHaveBeenCalled();

      const logged = parseLoggedPayload(warnSpy);
      expect(logged).toMatchObject({
        route: "/v1/backup",
        method: "PUT",
        requestID: expect.any(String),
        status: 400,
        errorCode: "invalid_request",
        errorDetails: {
          installID: "install_backup",
          hasExpectedRemoteVersion: false,
          hasBackupHash: false,
          hasSnapshot: true,
          snapshotCounts: {
            programs: 1,
            exercises: 1,
            history: 1,
          },
        },
        validationIssues: expect.arrayContaining([
          expect.objectContaining({
            code: "invalid_type",
            path: ["appVersion"],
            expected: "string",
            received: "number",
          }),
          expect.objectContaining({
            code: "invalid_type",
            path: ["buildNumber"],
            expected: "string",
            received: "number",
          }),
        ]),
      });
      expect(logged).not.toHaveProperty("snapshot");
      expect(logged).not.toHaveProperty("body");
      expect(JSON.stringify(logged)).not.toContain("Upper Lower");
      expect(JSON.stringify(logged)).not.toContain("Barbell Bench Press");
    } finally {
      warnSpy.mockRestore();
      errorSpy.mockRestore();
      logSpy.mockRestore();
    }
  });

  it("logs other client errors at warn level instead of error level", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    try {
      const response = await app.fetch(
        new Request("https://coach.example.workers.dev/v1/coach/profile-insights", {
          method: "POST",
          headers: {
            "content-type": "application/json",
          },
          body: JSON.stringify(makeProfileInsightsRequestFixture()),
        }),
        makeEnv()
      );

      expect(response.status).toBe(401);
      expect(warnSpy).toHaveBeenCalledTimes(1);
      expect(errorSpy).not.toHaveBeenCalled();
      expect(logSpy).not.toHaveBeenCalled();
      expect(parseLoggedPayload(warnSpy)).toMatchObject({
        route: "/v1/coach/profile-insights",
        method: "POST",
        status: 401,
        errorCode: "unauthorized",
      });
    } finally {
      warnSpy.mockRestore();
      errorSpy.mockRestore();
      logSpy.mockRestore();
    }
  });

  it("keeps unexpected 5xx errors on error-level logs", async () => {
    class FailingUploadRepository extends InMemoryCoachStateRepository {
      override async uploadBackup(_request: BackupUploadRequest): Promise<never> {
        throw new Error("simulated upload failure");
      }
    }

    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () =>
        new FailingUploadRepository("test.v1", DEFAULT_AI_MODEL),
    });
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    try {
      const response = await app.fetch(
        authedRequest("https://coach.example.workers.dev/v1/backup", {
          method: "PUT",
          body: JSON.stringify(makeBackupUploadRequestFixture()),
        }),
        makeEnv()
      );

      expect(response.status).toBe(500);
      await expect(response.json()).resolves.toMatchObject({
        error: {
          code: "internal_error",
        },
      });
      expect(errorSpy).toHaveBeenCalledTimes(1);
      expect(warnSpy).not.toHaveBeenCalled();
      expect(logSpy).not.toHaveBeenCalled();
      expect(parseLoggedPayload(errorSpy)).toMatchObject({
        route: "/v1/backup",
        method: "PUT",
        status: 500,
        errorCode: "internal_error",
        errorDetails: {
          installID: "install_backup",
          hasExpectedRemoteVersion: false,
          hasBackupHash: false,
          hasSnapshot: true,
          snapshotCounts: {
            programs: 1,
            exercises: 1,
            history: 1,
          },
        },
      });
    } finally {
      errorSpy.mockRestore();
      warnSpy.mockRestore();
      logSpy.mockRestore();
    }
  });

  it("maps invalid request bodies to 400", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/chat", {
        method: "POST",
        body: JSON.stringify({ locale: "en" }),
      }),
      makeEnv()
    );

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toMatchObject({
      error: {
        code: "invalid_request",
      },
    });
  });
});

describe("profile insights routing", () => {
  it("resolves the insights_fast role from INSIGHTS_FAST_MODEL before chat fast defaults", () => {
    const env = makeEnv({
      MODEL_ROUTING_ENABLED: "true",
      INSIGHTS_FAST_MODEL: "@cf/test/profile-fast",
    });

    expect(resolveModelForRole(env, "insights_fast")).toBe("@cf/test/profile-fast");
  });

  it("builds profile insights attempts in fast -> balanced -> quality -> plain-text order", () => {
    const env = makeEnv({
      MODEL_ROUTING_ENABLED: "true",
      INSIGHTS_FAST_MODEL: "@cf/test/profile-fast",
      INSIGHTS_BALANCED_MODEL: "@cf/test/profile-balanced",
      QUALITY_ESCALATION_ENABLED: "true",
      QUALITY_ESCALATION_MODEL: "@cf/test/profile-quality",
      SYNC_FALLBACK_MODEL: "@cf/test/profile-fallback",
    });

    const decision = buildProfileInsightsRoutingDecision(
      env,
      makeProfileInsightsRequestFixture()
    );
    const attempts = buildProfileInsightsRoutingAttempts(env, decision);

    expect(attempts.map((attempt) => [attempt.modelRole, attempt.mode])).toEqual([
      ["insights_fast", "structured"],
      ["insights_balanced", "structured"],
      ["quality_escalation", "structured"],
      ["sync_fallback", "plain_text_fallback"],
    ]);
    expect(attempts.map((attempt) => attempt.selectedModel)).toEqual([
      "@cf/test/profile-fast",
      "@cf/test/profile-balanced",
      "@cf/test/profile-quality",
      "@cf/test/profile-fallback",
    ]);
    expect(attempts.map((attempt) => attempt.fallbackHopCount)).toEqual([0, 1, 2, 3]);
  });

  it("dedupes profile insights attempts by effective model and mode", () => {
    const env = makeEnv({
      MODEL_ROUTING_ENABLED: "true",
      INSIGHTS_FAST_MODEL: "@cf/test/shared",
      INSIGHTS_BALANCED_MODEL: "@cf/test/shared",
      QUALITY_ESCALATION_ENABLED: "true",
      QUALITY_ESCALATION_MODEL: "@cf/test/shared",
      SYNC_FALLBACK_MODEL: "@cf/test/shared",
    });

    const decision = buildProfileInsightsRoutingDecision(
      env,
      makeProfileInsightsRequestFixture()
    );
    const attempts = buildProfileInsightsRoutingAttempts(env, decision);

    expect(attempts.map((attempt) => [attempt.selectedModel, attempt.mode])).toEqual([
      ["@cf/test/shared", "structured"],
      ["@cf/test/shared", "plain_text_fallback"],
    ]);
  });

  it("omits quality escalation when the feature is disabled", () => {
    const env = makeEnv({
      MODEL_ROUTING_ENABLED: "true",
      QUALITY_ESCALATION_ENABLED: "false",
    });

    const decision = buildProfileInsightsRoutingDecision(
      env,
      makeProfileInsightsRequestFixture()
    );
    const attempts = buildProfileInsightsRoutingAttempts(env, decision);

    expect(attempts.some((attempt) => attempt.modelRole === "quality_escalation")).toBe(
      false
    );
  });

  it("skips quality escalation when it resolves to the same model as insights_balanced", () => {
    const env = makeEnv({
      MODEL_ROUTING_ENABLED: "true",
      INSIGHTS_BALANCED_MODEL: "@cf/test/profile-balanced",
      QUALITY_ESCALATION_ENABLED: "true",
      QUALITY_ESCALATION_MODEL: "@cf/test/profile-balanced",
    });

    const decision = buildProfileInsightsRoutingDecision(
      env,
      makeProfileInsightsRequestFixture()
    );
    const attempts = buildProfileInsightsRoutingAttempts(env, decision);

    expect(attempts.some((attempt) => attempt.modelRole === "quality_escalation")).toBe(
      false
    );
  });
});

describe("WorkersAICoachService", () => {
  it("replays recent conversation turns and ignores previousResponseID", async () => {
    const aiRun = vi.fn().mockResolvedValue({
      response: {
        answerMarkdown: "Use +2.5kg if RPE stayed below 8.",
        followUps: ["Give me a double progression version."],
      },
      usage: { total_tokens: 321 },
    });

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const result = await service.generateChat(makeChatRequestFixture());

    expect(aiRun).toHaveBeenCalledTimes(1);
    const [model, payload] = aiRun.mock.calls[0] ?? [];
    expect(model).toBe(DEFAULT_AI_MODEL);
    expect(payload).toMatchObject({
      max_tokens: 700,
      temperature: 0.2,
      guided_json: expect.any(Object),
    });
    expect(payload?.guided_json?.properties).not.toHaveProperty("suggestedChanges");
    expect(payload).not.toHaveProperty("previous_response_id");
    expect(payload?.messages).toEqual(
      expect.arrayContaining([
        {
          role: "user",
          content: "Last week I was close to failure on my top sets.",
        },
        {
          role: "assistant",
          content: "Coach: keep one rep in reserve before pushing load.",
        },
      ])
    );
    const finalUserMessage = payload?.messages?.at(-1)?.content ?? "";
    expect(finalUserMessage).toContain("Sanitized coach context JSON:");
    expect(finalUserMessage).not.toContain("Coach analysis settings JSON:");
    expect(finalUserMessage).not.toContain("Selected program for analysis JSON:");
    expect(result.data.responseID).toMatch(/^coach-turn_/);
  });

  it("uses the GLM response_format adapter for fast-tier chat routing", async () => {
    const aiRun = vi.fn().mockResolvedValue({
      choices: [
        {
          message: {
            content: JSON.stringify({
              answerMarkdown: "Stay at the same load this week.",
              followUps: ["Give me a rep-target version."],
            }),
          },
        },
      ],
      usage: { total_tokens: 111 },
    });

    const service = new WorkersAICoachService(
      makeEnv({
        AI: { run: aiRun },
        MODEL_ROUTING_ENABLED: "true",
      })
    );
    const request = makeChatRequestFixture();
    request.clientRecentTurns = [];

    const result = await service.generateChat(request);

    expect(aiRun).toHaveBeenCalledTimes(1);
    const [model, payload] = aiRun.mock.calls[0] ?? [];
    expect(model).toBe("@cf/zai-org/glm-4.7-flash");
    expect(payload).toMatchObject({
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "coach_response",
          schema: expect.any(Object),
        },
      },
    });
    expect(payload).not.toHaveProperty("guided_json");
    expect(result.model).toBe("@cf/zai-org/glm-4.7-flash");
    expect(result.modelRole).toBe("chat_fast");
    expect(result.data.answerMarkdown).toBe("Stay at the same load this week.");
    expect(result.data.followUps).toEqual(["Give me a rep-target version."]);
  });

  it("normalizes follow-ups into user-side prompts and caps them at three", async () => {
    const aiRun = vi.fn().mockResolvedValue({
      response: {
        answerMarkdown: "You can either keep the split or simplify it.",
        followUps: [
          "Do you want to change your program?",
          "Want a 3-day version?",
          "Compare this with upper/lower.",
        ],
      },
    });

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const result = await service.generateChat(makeChatRequestFixture());

    expect(result.data.followUps).toEqual([
      "Help me change my program.",
      "Give me a 3-day version.",
      "Compare this with upper/lower.",
    ]);
  });

  it("builds a sanitized raw-first prompt and surfaces high-priority comment constraints", async () => {
    const aiRun = vi.fn().mockResolvedValue({
      response: {
        summary: "Summary",
        recommendations: ["Recommendation"],
      },
    });

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const request = makeProfileInsightsRequestFixture();
    request.snapshot = withStrictCommentConstraints(request.snapshot);
    await service.generateProfileInsights(request);

    const payload = aiRun.mock.calls[0]?.[1];
    const promptText = JSON.stringify(payload?.messages ?? []);

    expect(promptText).toContain("High-priority user constraints:");
    expect(promptText).toContain(
      "Do not recommend changing weekly training frequency."
    );
    expect(promptText).toContain("Goal summary JSON:");
    expect(promptText).toContain("Consistency summary JSON:");
    expect(promptText).toContain("30-day progress JSON:");
    expect(promptText).toContain("Preferred program summary JSON:");
    expect(promptText).not.toContain("Sanitized coach context JSON:");
    expect(promptText).not.toContain("Coach analysis settings JSON:");
    expect(promptText).not.toContain("Selected program for analysis JSON:");
    expect(promptText).not.toContain("\"selectedProgramID\"");
    expect(promptText).not.toContain(
      "55555555-5555-4555-8555-555555555555"
    );
    expect(promptText).not.toContain("\"compatibility\"");
    expect(promptText).not.toContain("\"training\"");
  });

  it("falls back to plain-text chat when structured output fails", async () => {
    const aiRun = vi
      .fn()
      .mockResolvedValueOnce({
        response: "not valid json",
      })
      .mockResolvedValueOnce({
        response: "Keep load the same next week and add one rep to the final set.",
      });

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const result = await service.generateChat(makeChatRequestFixture());

    expect(aiRun).toHaveBeenCalledTimes(2);
    expect(aiRun.mock.calls[1]?.[1]).not.toHaveProperty("guided_json");
    const fallbackPromptText = JSON.stringify(aiRun.mock.calls[1]?.[1]?.messages ?? []);
    expect(fallbackPromptText).not.toContain("Coach analysis settings JSON:");
    expect(fallbackPromptText).not.toContain("Selected program for analysis JSON:");
    expect(fallbackPromptText).not.toContain("\"selectedProgramID\"");
    expect(fallbackPromptText).not.toContain(
      "55555555-5555-4555-8555-555555555555"
    );
    expect(result.data.answerMarkdown).toBe(
      "Keep load the same next week and add one rep to the final set."
    );
    expect(result.data.followUps).toEqual([]);
    expect(result.data.responseID).toMatch(/^coach-turn_/);
  });

  it("falls back to plain-text chat when structured output times out and budget remains", async () => {
    const aiRun = vi
      .fn()
      .mockRejectedValueOnce(new Error("Request timed out"))
      .mockResolvedValueOnce({
        response:
          "Repeat the last successful load and add one rep only where the final set looked repeatable.",
      });

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const result = await service.generateChat(makeChatRequestFixture());

    expect(aiRun).toHaveBeenCalledTimes(2);
    expect(result.mode).toBe("plain_text_fallback");
    expect(result.data.answerMarkdown).toBe(
      "Repeat the last successful load and add one rep only where the final set looked repeatable."
    );
    expect(result.data.followUps).toEqual([]);
    expect(result.data.generationStatus).toBe("model");
  });

  it("applies the async chat fallback order before dropping to plain text", async () => {
    const aiRun = vi
      .fn()
      .mockRejectedValueOnce(new Error("Request timed out"))
      .mockResolvedValueOnce({ response: "not valid json" })
      .mockResolvedValueOnce({ response: "not valid json" })
      .mockResolvedValueOnce({ response: "not valid json" })
      .mockResolvedValueOnce({
        response:
          "Use the last repeatable load once more, then add a rep only if the final set still looks controlled.",
      });

    const service = new WorkersAICoachService(
      makeEnv({
        AI: { run: aiRun },
        MODEL_ROUTING_ENABLED: "true",
      })
    );
    const request = makeChatRequestFixture();
    request.clientRecentTurns = [];

    const result = await service.generateChat(request, {
      timeoutProfile: "async_job",
    });

    expect(aiRun).toHaveBeenCalledTimes(5);
    expect(aiRun.mock.calls.map(([model]) => model)).toEqual([
      "@cf/zai-org/glm-4.7-flash",
      "@cf/zai-org/glm-4.7-flash",
      DEFAULT_AI_MODEL,
      "@cf/meta/llama-3.1-8b-instruct-fast",
      "@cf/meta/llama-3.1-8b-instruct-fast",
    ]);
    expect(aiRun.mock.calls[0]?.[1]).toHaveProperty("response_format");
    expect(aiRun.mock.calls[1]?.[1]).toHaveProperty("response_format");
    expect(aiRun.mock.calls[2]?.[1]).toHaveProperty("guided_json");
    expect(aiRun.mock.calls[3]?.[1]).toHaveProperty("response_format");
    expect(aiRun.mock.calls[4]?.[1]).not.toHaveProperty("guided_json");
    expect(aiRun.mock.calls[4]?.[1]).not.toHaveProperty("response_format");
    expect(aiRun.mock.calls[0]?.[1]).toMatchObject({ max_tokens: 1400 });
    expect(aiRun.mock.calls[1]?.[1]).toMatchObject({ max_tokens: 700 });
    expect(result.mode).toBe("plain_text_fallback");
    expect(result.model).toBe("@cf/meta/llama-3.1-8b-instruct-fast");
    expect(result.modelRole).toBe("chat_reduced_context");
    expect(result.data.answerMarkdown).toContain(
      "Use the last repeatable load once more"
    );
  });

  it("removes leaked suggested-changes markdown from the chat answer", async () => {
    const aiRun = vi.fn().mockResolvedValue({
      response: {
        answerMarkdown: [
          "### Recovery check",
          "",
          "- Keep training volume stable this week.",
          "",
          "### Suggested Changes:",
          "",
          "```markdown",
          "- setWeeklyWorkoutTarget: 2",
          "```",
        ].join("\n"),
        followUps: [],
      },
    });

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const result = await service.generateChat(makeChatRequestFixture());

    expect(result.data.answerMarkdown).toContain("### Recovery check");
    expect(result.data.answerMarkdown).toContain(
      "Keep training volume stable this week."
    );
    expect(result.data.answerMarkdown).not.toContain("setWeeklyWorkoutTarget");
  });

  it("filters conflicting frequency and structure guidance from profile insights", async () => {
    const aiRun = vi.fn().mockResolvedValue({
      response: {
        summary: "Your saved program has 4 workouts, but weekly target is 3.",
        recommendations: [
          "Increase to 4 workouts per week so the split matches the target.",
          "Keep bench progression steady.",
        ],
      },
    });

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const request = makeProfileInsightsRequestFixture();
    request.snapshot = withStrictCommentConstraints(request.snapshot);
    const result = await service.generateProfileInsights(
      request
    );

    expect(result.data.summary).not.toContain("saved program has 4 workouts");
    expect(result.data.recommendations).toEqual(["Keep bench progression steady."]);
  });

  it("filters conflicting frequency and structure guidance from chat", async () => {
    const aiRun = vi.fn().mockResolvedValue({
      response: {
        answerMarkdown: [
          "Increase to 4 workouts per week so the split matches your target.",
          "Keep load the same next week and add one rep to the final set.",
        ].join("\n\n"),
        followUps: [],
      },
    });

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const request = makeChatRequestFixture();
    request.snapshot = withStrictCommentConstraints(request.snapshot);
    const result = await service.generateChat(request);

    expect(result.data.answerMarkdown).not.toContain("Increase to 4 workouts");
    expect(result.data.answerMarkdown).toContain(
      "Keep load the same next week and add one rep"
    );
  });

  it("parses plain-text profile insights", async () => {
    const aiRun = vi
      .fn()
      .mockResolvedValueOnce({
        response: "not valid json",
      })
      .mockResolvedValueOnce({
        response: [
          "Summary: Recovery is adequate.",
          "",
          "- Keep volume stable this week.",
        ].join("\n"),
      });

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const result = await service.generateProfileInsights(
      makeProfileInsightsRequestFixture()
    );

    expect(aiRun).toHaveBeenCalledTimes(2);
    expect(result.data.summary).toBe("Recovery is adequate.");
    expect(result.data.recommendations).toEqual([
      "Keep volume stable this week.",
    ]);
  });

  it("retries profile insights on balanced structured routing after a fast structured failure", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const aiRun = vi
      .fn()
      .mockResolvedValueOnce({
        response: "not valid json",
      })
      .mockResolvedValueOnce({
        response: {
          summary: "Balanced route succeeded.",
          recommendations: ["Keep the current weekly load stable."],
        },
      });

    try {
      const service = new WorkersAICoachService(
        makeEnv({
          AI: { run: aiRun },
          MODEL_ROUTING_ENABLED: "true",
          QUALITY_ESCALATION_ENABLED: "false",
        })
      );

      const result = await service.generateProfileInsights(
        makeProfileInsightsRequestFixture()
      );

      expect(aiRun.mock.calls.map(([model]) => model)).toEqual([
        "@cf/zai-org/glm-4.7-flash",
        DEFAULT_AI_MODEL,
      ]);
      expect(result.mode).toBe("structured");
      expect(result.model).toBe(DEFAULT_AI_MODEL);
      expect(result.modelRole).toBe("insights_balanced");
      expect(result.fallbackHopCount).toBe(1);
      expect(result.data.summary).toBe("Balanced route succeeded.");

      const warnEvents = parseLoggedPayloads(warnSpy).map((payload) => payload.event);
      const logPayloads = parseLoggedPayloads(logSpy);
      expect(warnEvents).toContain("coach_profile_attempt_failed");
      expect(logPayloads).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            event: "coach_profile_attempt_succeeded",
            selectedModel: DEFAULT_AI_MODEL,
            modelRole: "insights_balanced",
            fallbackHopCount: 1,
          }),
        ])
      );
    } finally {
      logSpy.mockRestore();
      warnSpy.mockRestore();
    }
  });

  it("falls back to sync_fallback plain text after structured profile insights failures", async () => {
    const aiRun = vi
      .fn()
      .mockResolvedValueOnce({
        response: "not valid json",
      })
      .mockResolvedValueOnce({
        response: "still not valid json",
      })
      .mockResolvedValueOnce({
        response: [
          "Summary: Sync fallback kept the response moving.",
          "",
          "- Hold volume steady for one more week.",
        ].join("\n"),
      });

    const service = new WorkersAICoachService(
      makeEnv({
        AI: { run: aiRun },
        MODEL_ROUTING_ENABLED: "true",
        QUALITY_ESCALATION_ENABLED: "false",
      })
    );
    const result = await service.generateProfileInsights(
      makeProfileInsightsRequestFixture()
    );

    expect(aiRun.mock.calls.map(([model]) => model)).toEqual([
      "@cf/zai-org/glm-4.7-flash",
      DEFAULT_AI_MODEL,
      "@cf/meta/llama-3.1-8b-instruct-fast",
    ]);
    expect(result.mode).toBe("plain_text_fallback");
    expect(result.model).toBe("@cf/meta/llama-3.1-8b-instruct-fast");
    expect(result.modelRole).toBe("sync_fallback");
    expect(result.data.summary).toBe("Sync fallback kept the response moving.");
    expect(result.data.recommendations).toEqual([
      "Hold volume steady for one more week.",
    ]);
  });

  it("drops to local fallback when the reserved plain-text budget is no longer available", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-03-27T00:00:00.000Z"));
    const aiRun = vi.fn().mockImplementation(() => {
      vi.setSystemTime(new Date("2026-03-27T00:00:22.600Z"));
      return Promise.reject(new Error("Request timed out"));
    });

    try {
      const service = new WorkersAICoachService(
        makeEnv({
          AI: { run: aiRun },
          MODEL_ROUTING_ENABLED: "true",
          QUALITY_ESCALATION_ENABLED: "true",
          QUALITY_ESCALATION_MODEL: "@cf/test/profile-quality",
        })
      );

      const result = await service.generateProfileInsights(
        makeProfileInsightsRequestFixture()
      );

      expect(aiRun).toHaveBeenCalledTimes(1);
      expect(result.mode).toBe("local_fallback");
      expect(result.fallbackReason).toBe("sync_budget_exhausted");
      expect(result.data.generationStatus).toBe("fallback");
      expect(result.data.insightSource).toBe("fallback");
    } finally {
      vi.useRealTimers();
    }
  });

  it("falls back to neutral local profile insights when inference fails", async () => {
    const aiRun = vi
      .fn()
      .mockRejectedValueOnce(new Error("Request timed out"))
      .mockRejectedValueOnce(new Error("Request timed out"));

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const result = await service.generateProfileInsights(
      makeProfileInsightsRequestFixture()
    );

    expect(aiRun).toHaveBeenCalledTimes(2);
    expect(result.data.summary.length).toBeGreaterThan(0);
    expect(result.data.recommendations.length).toBeGreaterThan(0);
    expect(result.data.summary.toLowerCase()).not.toContain("adjustments");
    expect(result.data.generationStatus).toBe("fallback");
    expect(result.data.insightSource).toBe("fallback");
  });

  it("falls back to plain-text profile insights when structured output times out and budget remains", async () => {
    const aiRun = vi
      .fn()
      .mockRejectedValueOnce(new Error("Request timed out"))
      .mockResolvedValueOnce({
        response: [
          "Summary: Recovery is under control.",
          "",
          "- Keep weekly load stable for one more week.",
        ].join("\n"),
      });

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const result = await service.generateProfileInsights(
      makeProfileInsightsRequestFixture()
    );

    expect(aiRun).toHaveBeenCalledTimes(2);
    expect(result.mode).toBe("plain_text_fallback");
    expect(result.data.summary).toBe("Recovery is under control.");
    expect(result.data.recommendations).toEqual([
      "Keep weekly load stable for one more week.",
    ]);
    expect(result.data.generationStatus).toBe("model");
    expect(result.data.insightSource).toBe("fresh_model");
  });

  it("cuts off long-running profile insight requests before the client disconnects", async () => {
    vi.useFakeTimers();
    try {
      const service = new WorkersAICoachService(
        makeEnv({
          AI: {
            run: vi.fn().mockImplementation(
              () => new Promise<unknown>(() => undefined)
            ),
          },
        })
      );

      const requestPromise = service.generateProfileInsights(
        makeProfileInsightsRequestFixture()
      );
      const expectation = expect(requestPromise).resolves.toMatchObject({
        data: {
          summary: expect.any(String),
        },
      });

      await vi.advanceTimersByTimeAsync(28_050);
      await expectation;
    } finally {
      vi.useRealTimers();
    }
  });

  it("degrades chat to a safe response when structured and fallback attempts time out", async () => {
    vi.useFakeTimers();
    try {
      const aiRun = vi
        .fn()
        .mockImplementation(() => new Promise<unknown>(() => undefined));
      const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));

      const requestPromise = service.generateChat(makeChatRequestFixture());
      const expectation = expect(requestPromise).resolves.toMatchObject({
        mode: "degraded_fallback",
        data: {
          answerMarkdown: expect.any(String),
          followUps: [],
          responseID: expect.stringMatching(/^coach-turn_/),
          generationStatus: "fallback",
        },
      });

      await vi.advanceTimersByTimeAsync(28_050);
      await expectation;
      expect(aiRun).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("reuses chat memory across routed model swaps when the compatibility key stays stable", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const memoryCompatibilityKey =
      "chat_markdown_v1:chat_async_default_v1:rich_async_family:compact_v1:phase1.v1";
    const fastKey = storageKeyFromMetadata(
      "ctx_hash_shared",
      {
        contextProfile: "rich_async_v1",
        routingVersion: "phase1.v1",
        memoryCompatibilityKey,
        selectedModel: "@cf/zai-org/glm-4.7-flash",
      },
      "test.v1",
      "@cf/zai-org/glm-4.7-flash"
    );
    const balancedKey = storageKeyFromMetadata(
      "ctx_hash_shared",
      {
        contextProfile: "rich_async_v1",
        routingVersion: "phase1.v1",
        memoryCompatibilityKey,
        selectedModel: DEFAULT_AI_MODEL,
      },
      "test.v1",
      DEFAULT_AI_MODEL
    );

    await repository.appendChatMemory(
      "install_001",
      fastKey,
      [],
      "How should I progress next week?",
      "Stay at the same load."
    );

    const reusedMemory = await repository.getChatMemory(
      "install_001",
      balancedKey
    );

    expect(reusedMemory?.recentTurns).toEqual([
      {
        role: "user",
        content: "How should I progress next week?",
      },
      {
        role: "assistant",
        content: "Stay at the same load.",
      },
    ]);
  });
});

function stubInferenceService(overrides?: {
  profileInsights?: CoachProfileInsightsResponse;
  workoutSummary?: CoachWorkoutSummaryResponse;
  chat?: CoachChatResponse;
  chatError?: Error;
  workoutSummaryError?: Error;
}): CoachInferenceService {
  return {
    async generateProfileInsights() {
      return {
        data: overrides?.profileInsights ?? {
          summary: "Summary",
          recommendations: ["Recommendation"],
          generationStatus: "model",
          insightSource: "fresh_model",
        },
        model: DEFAULT_AI_MODEL,
      };
    },
    async generateWorkoutSummary() {
      if (overrides?.workoutSummaryError) {
        throw overrides.workoutSummaryError;
      }
      return {
        data: overrides?.workoutSummary ?? {
          headline: "Workout completed",
          summary: "Solid session with repeatable work across the main lifts.",
          highlights: ["Top sets stayed consistent."],
          nextWorkoutFocus: ["Add load only where the last reps stayed clean."],
          generationStatus: "model",
        },
        model: DEFAULT_AI_MODEL,
      };
    },
    async generateChat() {
      if (overrides?.chatError) {
        throw overrides.chatError;
      }
      return {
        data: overrides?.chat ?? {
          answerMarkdown: "Answer",
          responseID: "coach-turn_1",
          followUps: [],
          generationStatus: "model",
        },
        responseId: "coach-turn_1",
        model: DEFAULT_AI_MODEL,
      };
    },
  };
}

function authedRequest(input: string, init: RequestInit): Request {
  return new Request(input, {
    ...init,
    headers: {
      authorization: "Bearer internal-token",
      "content-type": "application/json",
      ...(init.headers ?? {}),
    },
  });
}

function makeEnv(overrides: Partial<Env> = {}): Env {
  return {
    AI: {
      run: vi.fn(),
    },
    COACH_STATE_KV: {} as Env["COACH_STATE_KV"],
    BACKUPS_R2: {} as Env["BACKUPS_R2"],
    APP_META_DB: {} as Env["APP_META_DB"],
    COACH_CHAT_WORKFLOW: makeWorkflowBinding(vi.fn()),
    WORKOUT_SUMMARY_WORKFLOW: makeWorkflowBinding(vi.fn()),
    COACH_INTERNAL_TOKEN: "internal-token",
    AI_MODEL: DEFAULT_AI_MODEL,
    COACH_PROMPT_VERSION: "test.v1",
    MODEL_ROUTING_ENABLED: "false",
    MODEL_ROUTING_VERSION: "phase1.v1",
    CHAT_FAST_MODEL: "@cf/zai-org/glm-4.7-flash",
    CHAT_BALANCED_MODEL: DEFAULT_AI_MODEL,
    CHAT_REDUCED_CONTEXT_MODEL: "@cf/meta/llama-3.1-8b-instruct-fast",
    SUMMARY_FAST_MODEL: "@cf/zai-org/glm-4.7-flash",
    SUMMARY_BALANCED_MODEL: DEFAULT_AI_MODEL,
    SYNC_FALLBACK_MODEL: "@cf/meta/llama-3.1-8b-instruct-fast",
    INSIGHTS_FAST_MODEL: "@cf/zai-org/glm-4.7-flash",
    INSIGHTS_BALANCED_MODEL: DEFAULT_AI_MODEL,
    QUALITY_ESCALATION_ENABLED: "false",
    ...overrides,
  };
}

function makeWorkflowBinding(create: unknown): NonNullable<Env["COACH_CHAT_WORKFLOW"]> {
  return {
    create: create as NonNullable<Env["COACH_CHAT_WORKFLOW"]>["create"],
    get: vi.fn().mockResolvedValue(
      makeWorkflowInstanceStub()
    ) as NonNullable<Env["COACH_CHAT_WORKFLOW"]>["get"],
  };
}

function makeWorkflowInstanceStub() {
  return {
    id: "workflow-instance",
    status: vi.fn().mockResolvedValue({ status: "queued" }),
  };
}

function parseLoggedPayload(mock: { mock: { calls: unknown[][] } }): Record<string, unknown> {
  const payload = mock.mock.calls[0]?.[0];
  if (typeof payload !== "string") {
    throw new Error("Expected a serialized log payload.");
  }

  return JSON.parse(payload) as Record<string, unknown>;
}

function parseLoggedPayloads(mock: { mock: { calls: unknown[][] } }): Record<string, unknown>[] {
  return mock.mock.calls
    .map((call) => call[0])
    .filter((payload): payload is string => typeof payload === "string")
    .map((payload) => JSON.parse(payload) as Record<string, unknown>);
}

function makeBackupUploadRequestFixture(): BackupUploadRequest {
  return {
    installID: "install_backup",
    clientSourceModifiedAt: "2026-03-25T19:00:00.000Z",
    appVersion: "1.0.0",
    buildNumber: "100",
    snapshot: makeAppSnapshotFixture(),
  };
}

function makeAppSnapshotFixture(): AppSnapshotPayload {
  return {
    programs: [
      {
        id: "11111111-1111-4111-8111-111111111111",
        title: "Upper Lower",
        workouts: [
          {
            id: "22222222-2222-4222-8222-222222222222",
            title: "Upper A",
            focus: "Chest and back",
            exercises: [
              {
                id: "33333333-3333-4333-8333-333333333333",
                exerciseID: "44444444-4444-4444-8444-444444444444",
                sets: [
                  { id: "33333333-0000-4000-8000-333333333333", reps: 5, suggestedWeight: 90 },
                  { id: "33333333-0000-4000-8000-333333333334", reps: 5, suggestedWeight: 90 },
                ],
                groupKind: "regular",
              },
            ],
          },
        ],
      },
    ],
    exercises: [
      {
        id: "44444444-4444-4444-8444-444444444444",
        name: "Barbell Bench Press",
        categoryID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
        equipment: "Barbell",
        notes: "",
      },
    ],
    history: [
      {
        id: "55555555-5555-4555-8555-555555555555",
        workoutTemplateID: "22222222-2222-4222-8222-222222222222",
        title: "Upper A",
        startedAt: "2026-03-24T17:00:00.000Z",
        endedAt: "2026-03-24T18:00:00.000Z",
        exercises: [
          {
            id: "66666666-6666-4666-8666-666666666666",
            templateExerciseID: "33333333-3333-4333-8333-333333333333",
            exerciseID: "44444444-4444-4444-8444-444444444444",
            groupKind: "regular",
            sets: [
              {
                id: "77777777-7777-4777-8777-777777777777",
                reps: 5,
                weight: 100,
                completedAt: "2026-03-24T17:20:00.000Z",
              },
              {
                id: "88888888-8888-4888-8888-888888888888",
                reps: 5,
                weight: 102.5,
                completedAt: "2026-03-24T17:30:00.000Z",
              },
            ],
          },
        ],
      },
    ],
    profile: {
      sex: "M",
      age: 29,
      weight: 86,
      height: 182,
      appLanguageCode: "en",
      primaryGoal: "strength",
      experienceLevel: "intermediate",
      weeklyWorkoutTarget: 4,
      targetBodyWeight: 88,
    },
    coachAnalysisSettings: {
      selectedProgramID: "11111111-1111-4111-8111-111111111111",
      programComment:
        "I train 3 days per week but rotate through this 4-day split in order.",
    },
  };
}

function makeCompactSnapshotFixture(): CompactCoachSnapshot {
  return buildCoachContextFromSnapshot({
    snapshot: makeAppSnapshotFixture(),
    runtimeContextDelta: {
      activeWorkout: {
        workoutTemplateID: "22222222-2222-4222-8222-222222222222",
        title: "Upper A",
        startedAt: "2026-03-25T12:00:00.000Z",
        exerciseCount: 1,
        completedSetsCount: 1,
        totalSetsCount: 2,
      },
    },
  });
}

function makeProfileInsightsRequestFixture(): CoachProfileInsightsRequest {
  return {
    locale: "en",
    installID: "install_001",
    snapshotHash: "a36c44a10cafe4ec5d406e8addcc7adc4a3cd72c3b11ee848b2b6cff2255b382",
    snapshot: makeCompactSnapshotFixture(),
    snapshotUpdatedAt: "2026-03-25T19:00:00.000Z",
    capabilityScope: "draft_changes",
    forceRefresh: false,
  };
}

function makeChatRequestFixture(): CoachChatRequest {
  const {
    locale,
    installID,
    snapshotHash,
    snapshot,
    snapshotUpdatedAt,
    runtimeContextDelta,
    capabilityScope,
  } = makeProfileInsightsRequestFixture();

  return {
    locale,
    installID,
    snapshotHash,
    snapshot,
    snapshotUpdatedAt,
    runtimeContextDelta,
    capabilityScope,
    question: "How should I progress next week?",
    clientRecentTurns: [
      {
        role: "user",
        content: "Last week I was close to failure on my top sets.",
      },
      {
        role: "assistant",
        content: "Coach: keep one rep in reserve before pushing load.",
      },
    ],
  };
}

function makeChatJobCreateRequestFixture(): CoachChatJobCreateRequest {
  return {
    ...makeChatRequestFixture(),
    clientRequestID: crypto.randomUUID(),
  };
}

function makeWorkoutSummaryJobCreateRequestFixture(): CoachWorkoutSummaryJobCreateRequest {
  return {
    locale: "en",
    installID: "install_001",
    clientRequestID: crypto.randomUUID(),
    sessionID: "99999999-9999-4999-8999-999999999999",
    fingerprint:
      "7ce662704328b0c3ab015f053ec2778335f3d6958d51561d72163131855f6353",
    requestMode: "prewarm",
    trigger: "prewarm_one_remaining_set",
    inputMode: "projected_final",
    currentWorkout: {
      workoutTemplateID: "22222222-2222-4222-8222-222222222222",
      title: "Upper A",
      exerciseCount: 1,
      completedSetsCount: 2,
      totalSetsCount: 2,
      totalVolume: 1012.5,
      exercises: [
        {
          templateExerciseID: "33333333-3333-4333-8333-333333333333",
          exerciseID: "44444444-4444-4444-8444-444444444444",
          exerciseName: "Barbell Bench Press",
          groupKind: "regular",
          sets: [
            { index: 0, reps: 5, weight: 100, isCompleted: true },
            { index: 1, reps: 5, weight: 102.5, isCompleted: true },
          ],
          completedSetsCount: 2,
          totalSetsCount: 2,
          totalVolume: 1012.5,
        },
      ],
    },
    recentExerciseHistory: [
      {
        exerciseID: "44444444-4444-4444-8444-444444444444",
        exerciseName: "Barbell Bench Press",
        sessions: [
          {
            sessionID: "55555555-5555-4555-8555-555555555555",
            workoutTitle: "Upper A",
            startedAt: "2026-03-24T17:00:00.000Z",
            completedSetsCount: 2,
            bestWeight: 102.5,
            averageReps: 5,
            totalVolume: 1012.5,
            completedSets: [
              { reps: 5, weight: 100 },
              { reps: 5, weight: 102.5 },
            ],
          },
        ],
      },
    ],
  };
}

function withStrictCommentConstraints(
  snapshot: CompactCoachSnapshot | undefined
): CompactCoachSnapshot | undefined {
  if (!snapshot) {
    return snapshot;
  }

  return {
    ...snapshot,
    coachAnalysisSettings: {
      ...snapshot.coachAnalysisSettings,
      programComment:
        "I train 3 days per week and rotate through this 4-day split in order. Do not change weekly training frequency or the number of workout days in the program.",
    },
  };
}
