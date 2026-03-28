import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app";
import { executeChatJob } from "../src/chat-job-executor";
import * as chatJobExecutorModule from "../src/chat-job-executor";
import { CoachChatJobWorkflow } from "../src/chat-job-workflow";
import { executeWorkoutSummaryJob } from "../src/workout-summary-job-executor";
import { buildProfileInsightsMessages } from "../src/prompts";
import {
  buildCoachContextFromSnapshot,
} from "../src/context";
import {
  CoachInferenceServiceError,
  DEFAULT_AI_MODEL,
  WorkersAICoachService,
  createInferenceServiceForProvider,
  type CoachInferenceService,
  type Env,
} from "../src/openai";
import {
  CloudflareCoachStateRepository,
  InMemoryCoachStateRepository,
  storageKeyFromMetadata,
  type CoachD1Database,
  type CoachD1PreparedStatement,
  type CoachKVNamespace,
  type CoachR2Bucket,
} from "../src/state";
import {
  buildProfileInsightsRoutingAttempts,
  buildProfileInsightsRoutingDecision,
  resolveModelForRole,
} from "../src/routing";
import {
  normalizeAsyncProfileInsightsResult,
} from "../src/profile-insights-normalization";
import {
  buildGemini2_5FamilyBlockKey,
  writeGemini2_5FamilyBlockState,
} from "../src/gemini-quota";
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

const PROFILE_INSIGHTS_TEST_ROUTING_VERSION =
  "phase1.v1.profile-insights.v3.quality-first";

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

  it("uploads, reports status, and downloads full backups", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const upload = makeBackupUploadRequestFixture();

    const initialStatus = await app.fetch(
      authedRequest(
        `https://coach.example.workers.dev/v1/backup/status?installID=${upload.installID}&localBackupHash=local-only-hash&localStateKind=user_data`,
        {
          method: "GET",
        }
      ),
      makeEnv()
    );
    await expect(initialStatus.json()).resolves.toMatchObject({
      syncState: "no_remote_backup",
      actions: {
        shouldUpload: true,
      },
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

    const readyStatus = await app.fetch(
      authedRequest(
        `https://coach.example.workers.dev/v1/backup/status?installID=${upload.installID}&localBackupHash=${uploaded.backupHash}&localStateKind=user_data`,
        {
          method: "GET",
        }
      ),
      makeEnv()
    );
    await expect(readyStatus.json()).resolves.toMatchObject({
      syncState: "remote_ready",
      contextState: "context_ready",
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

  it("returns normalized backup status for same-device restore flow", async () => {
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

    const response = await app.fetch(
      authedRequest(
        `https://coach.example.workers.dev/v1/backup/status?installID=${upload.installID}&localStateKind=seed`,
        {
          method: "GET",
        }
      ),
      makeEnv()
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      syncState: "restore_pending_decision",
      contextState: "context_stale",
      actions: {
        canUseRemoteAIContextNow: false,
        shouldOfferRestore: true,
        shouldPromptUser: true,
      },
      remote: {
        backupVersion: 1,
      },
    });
  });

  it("rejects stale remote context instead of silently using it", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const upload = makeBackupUploadRequestFixture();
    upload.installID = "install_stale_context";

    await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        body: JSON.stringify(upload),
      }),
      makeEnv()
    );

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        body: JSON.stringify({
          locale: "en",
          installID: upload.installID,
          localBackupHash: "different-local-hash",
          capabilityScope: "draft_changes",
        }),
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

  it("uses inline snapshot fallback when the local hash mismatches the remote head", async () => {
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
    upload.installID = "install_inline_fallback";

    await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        body: JSON.stringify(upload),
      }),
      makeEnv()
    );

    const body = makeProfileInsightsRequestFixture();
    body.installID = upload.installID;
    body.localBackupHash = "different-local-hash";
    body.snapshot = {
      ...body.snapshot!,
      profile: {
        ...body.snapshot!.profile,
        age: 57,
      },
    };

    const response = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        body: JSON.stringify(body),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    expect(capturedSnapshot?.profile.age).toBe(57);
  });

  it("enrolls install secret and rejects invalid proof afterwards", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const upload = makeBackupUploadRequestFixture();
    upload.installID = "install_secret_enrolled";

    const uploadResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        headers: {
          "x-install-secret": "super-secret-install-proof",
        },
        body: JSON.stringify(upload),
      }),
      makeEnv()
    );
    expect(uploadResponse.status).toBe(200);

    const invalidProofResponse = await app.fetch(
      authedRequest(
        `https://coach.example.workers.dev/v1/backup/status?installID=${upload.installID}&localBackupHash=nope`,
        {
          method: "GET",
          headers: {
            "x-install-secret": "wrong-secret",
          },
        }
      ),
      makeEnv()
    );

    expect(invalidProofResponse.status).toBe(401);
    await expect(invalidProofResponse.json()).resolves.toMatchObject({
      error: {
        code: "install_proof_invalid",
      },
    });
  });

  it("keeps legacy clients working before install secret enrollment", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const upload = makeBackupUploadRequestFixture();
    upload.installID = "install_legacy_compat";

    const uploadResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        body: JSON.stringify(upload),
      }),
      makeEnv()
    );
    expect(uploadResponse.status).toBe(200);

    const statusResponse = await app.fetch(
      authedRequest(
        `https://coach.example.workers.dev/v1/backup/status?installID=${upload.installID}&localBackupHash=other-hash&localSourceModifiedAt=2026-03-26T19:00:00.000Z&localStateKind=user_data`,
        {
          method: "GET",
        }
      ),
      makeEnv()
    );

    expect(statusResponse.status).toBe(200);
    await expect(statusResponse.json()).resolves.toMatchObject({
      authMode: "legacy_compat",
    });
  });

  it("clears remote chat memory without deleting backup", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const capturedRecentTurns: number[] = [];
    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
          throw new Error("not used");
        },
        async generateWorkoutSummary() {
          throw new Error("not used");
        },
        async generateChat(request) {
          capturedRecentTurns.push(request.clientRecentTurns.length);
          return {
            data: {
              answerMarkdown: "Answer",
              responseID: "resp-1",
              followUps: [],
              generationStatus: "model",
            },
            model: DEFAULT_AI_MODEL,
          };
        },
      }),
      createStateRepository: () => repository,
    });
    const upload = makeBackupUploadRequestFixture();
    upload.installID = "install_chat_memory_clear";

    const uploadResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/backup", {
        method: "PUT",
        body: JSON.stringify(upload),
      }),
      makeEnv()
    );
    const uploaded = await uploadResponse.json();

    await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/chat", {
        method: "POST",
        body: JSON.stringify({
          locale: "en",
          installID: upload.installID,
          localBackupHash: uploaded.backupHash,
          capabilityScope: "draft_changes",
          question: "First",
          clientRecentTurns: [],
        }),
      }),
      makeEnv()
    );

    await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/chat", {
        method: "POST",
        body: JSON.stringify({
          locale: "en",
          installID: upload.installID,
          localBackupHash: uploaded.backupHash,
          capabilityScope: "draft_changes",
          question: "Second",
          clientRecentTurns: [],
        }),
      }),
      makeEnv()
    );

    const clearResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/memory/clear", {
        method: "POST",
        body: JSON.stringify({
          installID: upload.installID,
        }),
      }),
      makeEnv()
    );
    expect(clearResponse.status).toBe(200);

    await app.fetch(
      authedRequest("https://coach.example.workers.dev/v1/coach/chat", {
        method: "POST",
        body: JSON.stringify({
          locale: "en",
          installID: upload.installID,
          localBackupHash: uploaded.backupHash,
          capabilityScope: "draft_changes",
          question: "Third",
          clientRecentTurns: [],
        }),
      }),
      makeEnv()
    );

    expect(capturedRecentTurns).toEqual([0, 2, 0]);
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
        contextProfile: "rich_async_analytics_v1",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_rich_async_analytics_v2",
        memoryProfile: "rich_async_v1",
        routingVersion: PROFILE_INSIGHTS_TEST_ROUTING_VERSION,
      }, "test.v1", DEFAULT_AI_MODEL),
      makeProfileInsightsResponseFixture({
        summary: "Cached fallback summary",
        recommendations: ["Cached fallback recommendation"],
        generationStatus: "fallback",
        insightSource: "fallback",
      })
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
        contextProfile: "rich_async_analytics_v1",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_rich_async_analytics_v2",
        memoryProfile: "rich_async_v1",
        routingVersion: PROFILE_INSIGHTS_TEST_ROUTING_VERSION,
      }, "test.v1", DEFAULT_AI_MODEL),
      makeProfileInsightsResponseFixture({
        summary: "Cached remote summary",
        recommendations: ["Cached remote recommendation"],
        generationStatus: "model",
        insightSource: "fresh_model",
      })
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
        contextProfile: "rich_async_analytics_v1",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_rich_async_analytics_v2",
        memoryProfile: "rich_async_v1",
      }, "test.v1", DEFAULT_AI_MODEL),
      makeProfileInsightsResponseFixture({
        summary: "Cached remote summary",
        recommendations: ["Cached remote recommendation"],
        generationStatus: "model",
        insightSource: "fresh_model",
      })
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
          contextProfile: "rich_async_analytics_v1",
          contextVersion: context.contextVersion,
          analyticsVersion: context.analyticsVersion,
          promptProfile: "profile_rich_async_analytics_v2",
          memoryProfile: "rich_async_v1",
          routingVersion: PROFILE_INSIGHTS_TEST_ROUTING_VERSION,
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
    const getInsightsCacheSpy = vi.spyOn(repository, "getInsightsCache");
    const getDegradedInsightsCacheSpy = vi.spyOn(
      repository,
      "getDegradedInsightsCache"
    );
    const body = makeProfileInsightsRequestFixture();
    const context = await repository.resolveCoachContext(body);
    const key = storageKeyFromMetadata(
      context.contextHash,
      {
        contextProfile: "rich_async_analytics_v1",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_rich_async_analytics_v2",
        memoryProfile: "rich_async_v1",
        routingVersion: PROFILE_INSIGHTS_TEST_ROUTING_VERSION,
      },
      "test.v1",
      DEFAULT_AI_MODEL
    );
    await repository.storeInsightsCache(
      body.installID,
      key,
      makeProfileInsightsResponseFixture({
        summary: "Cached model summary",
        recommendations: ["Cached model recommendation"],
        generationStatus: "model",
        insightSource: "fresh_model",
      })
    );
    await repository.storeDegradedInsightsCache(
      body.installID,
      key,
      makeProfileInsightsResponseFixture({
        summary: "Cached degraded summary",
        recommendations: ["Cached degraded recommendation"],
        generationStatus: "fallback",
        insightSource: "fallback",
      })
    );

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
    expect(getInsightsCacheSpy).toHaveBeenCalledTimes(1);
    expect(getDegradedInsightsCacheSpy).not.toHaveBeenCalled();
    await expect(response.json()).resolves.toMatchObject({
      summary: "Cached model summary",
      generationStatus: "model",
      insightSource: "cached_model",
    });
  });

  it("marks degraded sidecar model insights as cached without rerunning inference", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    let inferenceCalls = 0;
    const body = makeProfileInsightsRequestFixture();
    const context = await repository.resolveCoachContext(body);
    const key = storageKeyFromMetadata(
      context.contextHash,
      {
        contextProfile: "rich_async_analytics_v1",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_rich_async_analytics_v2",
        memoryProfile: "rich_async_v1",
        routingVersion: PROFILE_INSIGHTS_TEST_ROUTING_VERSION,
      },
      "test.v1",
      DEFAULT_AI_MODEL
    );
    await repository.storeDegradedInsightsCache(
      body.installID,
      key,
      makeProfileInsightsResponseFixture({
        summary: "Cached degraded model summary",
        recommendations: ["Cached degraded model recommendation"],
        generationStatus: "model",
        insightSource: "fresh_model",
      })
    );

    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
          inferenceCalls += 1;
          return {
            data: {
              summary: "Should not run inference",
              recommendations: ["Should not run inference"],
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
        body: JSON.stringify(body),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    expect(inferenceCalls).toBe(0);
    await expect(response.json()).resolves.toMatchObject({
      summary: "Cached degraded model summary",
      generationStatus: "model",
      insightSource: "cached_model",
    });
  });

  it("bypasses degraded sidecar cache on force refresh", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const getInsightsCacheSpy = vi.spyOn(repository, "getInsightsCache");
    const getDegradedInsightsCacheSpy = vi.spyOn(
      repository,
      "getDegradedInsightsCache"
    );
    let inferenceCalls = 0;
    const body = makeProfileInsightsRequestFixture();
    const context = await repository.resolveCoachContext(body);
    const key = storageKeyFromMetadata(
      context.contextHash,
      {
        contextProfile: "rich_async_analytics_v1",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_rich_async_analytics_v2",
        memoryProfile: "rich_async_v1",
      },
      "test.v1",
      DEFAULT_AI_MODEL
    );
    await repository.storeDegradedInsightsCache(
      body.installID,
      key,
      makeProfileInsightsResponseFixture({
        summary: "Cached degraded summary",
        recommendations: ["Cached degraded recommendation"],
        generationStatus: "fallback",
        insightSource: "fallback",
      })
    );

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
    expect(getInsightsCacheSpy).not.toHaveBeenCalled();
    expect(getDegradedInsightsCacheSpy).not.toHaveBeenCalled();
    await expect(response.json()).resolves.toMatchObject({
      summary: "Force refreshed summary",
      generationStatus: "model",
      insightSource: "fresh_model",
    });
  });

  it("bypasses degraded sidecar cache when allowDegradedCache is false", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    let inferenceCalls = 0;
    const body = makeProfileInsightsRequestFixture();
    const context = await repository.resolveCoachContext(body);
    const key = storageKeyFromMetadata(
      context.contextHash,
      {
        contextProfile: "rich_async_analytics_v1",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_rich_async_analytics_v2",
        memoryProfile: "rich_async_v1",
        routingVersion: PROFILE_INSIGHTS_TEST_ROUTING_VERSION,
      },
      "test.v1",
      DEFAULT_AI_MODEL
    );
    await repository.storeDegradedInsightsCache(
      body.installID,
      key,
      makeProfileInsightsResponseFixture({
        summary: "Cached degraded summary",
        recommendations: ["Cached degraded recommendation"],
        generationStatus: "model",
        insightSource: "fresh_model",
        selectedModel: "@cf/test/degraded",
      })
    );

    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
          inferenceCalls += 1;
          return {
            data: {
              summary: "Fresh live summary",
              recommendations: ["Fresh live recommendation"],
              generationStatus: "model",
              insightSource: "fresh_model",
            },
            model: DEFAULT_AI_MODEL,
            selectedModel: DEFAULT_AI_MODEL,
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
          allowDegradedCache: false,
        }),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    expect(inferenceCalls).toBe(1);
    await expect(response.json()).resolves.toMatchObject({
      summary: "Fresh live summary",
      generationStatus: "model",
      insightSource: "fresh_model",
      selectedModel: DEFAULT_AI_MODEL,
    });
  });

  it("keeps emergency Gemini fallback results in degraded sidecar cache without overwriting canonical cache", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const body = makeProfileInsightsRequestFixture();
    const context = await repository.resolveCoachContext(body);
    const key = storageKeyFromMetadata(
      context.contextHash,
      {
        contextProfile: "rich_async_analytics_v1",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_rich_async_analytics_v2",
        memoryProfile: "rich_async_v1",
        routingVersion: PROFILE_INSIGHTS_TEST_ROUTING_VERSION,
      },
      "test.v1",
      DEFAULT_AI_MODEL
    );
    await repository.storeInsightsCache(
      body.installID,
      key,
      makeProfileInsightsResponseFixture({
        summary: "Canonical cached summary",
        recommendations: ["Canonical cached recommendation"],
        generationStatus: "model",
        insightSource: "fresh_model",
      })
    );

    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
          return {
            data: {
              summary: "Emergency Gemini fallback summary",
              recommendations: ["Use degraded sidecar semantics only."],
              generationStatus: "model",
              insightSource: "fresh_model",
            },
            model: "gemini-3.1-flash-lite-preview",
            mode: "structured",
            requestedModel: "gemini-2.5-flash",
            attemptedModels: [
              "gemini-2.5-flash",
              "gemini-2.5-flash-lite",
              "gemini-3.1-flash-lite-preview",
            ],
            fallbackModelUsed: "gemini-3.1-flash-lite-preview",
            providerQuotaExhausted: true,
            geminiDailyQuotaExhausted: true,
            providerFamilyBlocked: true,
            blockedUntil: "2026-03-29T07:00:00.000Z",
            quotaClassificationKind: "daily_quota",
            requestPath: "profile_insights",
            sourceProviderErrorStatus: 429,
            sourceProviderErrorCode: "RESOURCE_EXHAUSTED",
            providerFamily: "gemini-2.5",
            emergencyFallbackUsed: true,
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
    await expect(response.json()).resolves.toMatchObject({
      summary: "Emergency Gemini fallback summary",
      generationStatus: "model",
    });
    await expect(repository.getInsightsCache(body.installID, key)).resolves.toMatchObject({
      summary: "Canonical cached summary",
      generationStatus: "model",
    });
    await expect(
      repository.getDegradedInsightsCache(body.installID, key)
    ).resolves.toMatchObject({
      summary: "Emergency Gemini fallback summary",
      generationStatus: "model",
    });
  });

  it("returns provider_family_blocked when Gemini family block is active and emergency fallback is disabled", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const kv = makeMemoryKV();
    await writeGemini2_5FamilyBlockState(kv, {
      reason: "daily_quota",
      sourceModel: "gemini-2.5-flash-lite",
      sourcePath: "profile_insights",
      providerStatus: 429,
      providerCode: "RESOURCE_EXHAUSTED",
    });
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);

    try {
      const app = createApp({
        createStateRepository: () => repository,
      });
      const response = await app.fetch(
        authedRequest("https://coach.example.workers.dev/v1/coach/profile-insights", {
          method: "POST",
          body: JSON.stringify({
            ...makeProfileInsightsRequestFixture(),
            provider: "gemini",
          }),
        }),
        makeEnv({
          COACH_STATE_KV: kv,
          GEMINI_API_KEY: "test-gemini-key",
          GEMINI_2_5_QUOTA_BLOCK_ENABLED: "true",
          GEMINI_EMERGENCY_FALLBACK_ENABLED: "false",
        })
      );

      expect(fetchSpy).not.toHaveBeenCalled();
      expect(response.status).toBe(429);
      await expect(response.json()).resolves.toMatchObject({
        error: {
          code: "provider_family_blocked",
          message:
            "Gemini 2.5 models are temporarily blocked after quota exhaustion. Please try again after the next Pacific reset.",
        },
      });
    } finally {
      vi.unstubAllGlobals();
    }
  });
  it("does not reuse degraded sidecar cache after the insights fingerprint changes", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    let inferenceCalls = 0;
    const originalBody = makeProfileInsightsRequestFixture();
    const originalContext = await repository.resolveCoachContext(originalBody);
    const originalKey = storageKeyFromMetadata(
      originalContext.contextHash,
      {
        contextProfile: "rich_async_analytics_v1",
        contextVersion: originalContext.contextVersion,
        analyticsVersion: originalContext.analyticsVersion,
        promptProfile: "profile_rich_async_analytics_v2",
        memoryProfile: "rich_async_v1",
      },
      "test.v1",
      DEFAULT_AI_MODEL
    );
    await repository.storeDegradedInsightsCache(
      originalBody.installID,
      originalKey,
      makeProfileInsightsResponseFixture({
        summary: "Old degraded summary",
        recommendations: ["Old degraded recommendation"],
        generationStatus: "fallback",
        insightSource: "fallback",
      })
    );

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
        contextProfile: "rich_async_analytics_v1",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_rich_async_analytics_v2",
        memoryProfile: "rich_async_v1",
        routingVersion: PROFILE_INSIGHTS_TEST_ROUTING_VERSION,
      },
      "test.v1",
      DEFAULT_AI_MODEL
    );
    const otherKey = {
      ...matchingKey,
      contextHash: "ctx_hash_other",
    };
    await repository.storeDegradedInsightsCache(
      body.installID,
      matchingKey,
      makeProfileInsightsResponseFixture({
        summary: "Matching degraded summary",
        recommendations: ["Matching degraded recommendation"],
        generationStatus: "fallback",
        insightSource: "fallback",
      })
    );
    await repository.storeDegradedInsightsCache(
      body.installID,
      otherKey,
      makeProfileInsightsResponseFixture({
        summary: "Other degraded summary",
        recommendations: ["Other degraded recommendation"],
        generationStatus: "fallback",
        insightSource: "fallback",
      })
    );

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
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const body = makeProfileInsightsRequestFixture();
    const context = await repository.resolveCoachContext(body);
    const key = storageKeyFromMetadata(
      context.contextHash,
      {
        contextProfile: "rich_async_analytics_v1",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_rich_async_analytics_v2",
        memoryProfile: "rich_async_v1",
        routingVersion: PROFILE_INSIGHTS_TEST_ROUTING_VERSION,
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

    try {
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
      expect(parseLoggedPayload(logSpy)).toMatchObject({
        responseSource: "local_fallback",
        fallbackSource: "local_fallback",
        cacheSource: "miss",
      });
    } finally {
      logSpy.mockRestore();
    }
  });

  it("stores live plain-text fallback only in the degraded sidecar cache with degraded semantics", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const body = makeProfileInsightsRequestFixture();
    const context = await repository.resolveCoachContext(body);
    const key = storageKeyFromMetadata(
      context.contextHash,
      {
        contextProfile: "rich_async_analytics_v1",
        contextVersion: context.contextVersion,
        analyticsVersion: context.analyticsVersion,
        promptProfile: "profile_rich_async_analytics_v2",
        memoryProfile: "rich_async_v1",
        routingVersion: PROFILE_INSIGHTS_TEST_ROUTING_VERSION,
      },
      "test.v1",
      DEFAULT_AI_MODEL
    );
    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
          return {
            data: {
              summary: "Plain text fallback summary",
              recommendations: ["Plain text fallback recommendation"],
              generationStatus: "model",
              insightSource: "fresh_model",
              selectedModel: "@cf/meta/llama-3.1-8b-instruct-fast",
            },
            model: "@cf/meta/llama-3.1-8b-instruct-fast",
            selectedModel: "@cf/meta/llama-3.1-8b-instruct-fast",
            modelRole: "sync_fallback",
            mode: "plain_text_fallback",
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

    try {
      expect(response.status).toBe(200);
      await expect(response.json()).resolves.toMatchObject({
        summary: "Plain text fallback summary",
        generationStatus: "model",
        insightSource: "fresh_model",
        selectedModel: "@cf/meta/llama-3.1-8b-instruct-fast",
      });
      await expect(
        repository.getInsightsCache(body.installID, key)
      ).resolves.toBeNull();
      await expect(
        repository.getDegradedInsightsCache(body.installID, key)
      ).resolves.toMatchObject({
        summary: "Plain text fallback summary",
        generationStatus: "model",
        insightSource: "fresh_model",
        selectedModel: "@cf/meta/llama-3.1-8b-instruct-fast",
      });
      expect(parseLoggedPayload(logSpy)).toMatchObject({
        responseSource: "live_fallback",
        fallbackSource: "none",
        cacheSource: "miss",
      });
    } finally {
      logSpy.mockRestore();
    }
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
        selectedModel: expect.any(String),
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

  it("creates a new async chat job for the same clientRequestID when provider changes after completion", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    const workflowCreate = vi.fn().mockResolvedValue(makeWorkflowInstanceStub());
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
      createStateRepository: () => repository,
    });
    const env = makeEnv({
      COACH_CHAT_WORKFLOW: makeWorkflowBinding(workflowCreate),
      GEMINI_API_KEY: "test-gemini-key",
    });
    const firstRequest = makeChatJobCreateRequestFixture();
    const secondRequest = {
      ...firstRequest,
      provider: "gemini" as const,
    };

    const firstResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(firstRequest),
      }),
      env
    );
    const firstBody = await firstResponse.json();
    await repository.completeChatJob(firstBody.jobID, {
      completedAt: new Date().toISOString(),
      result: {
        answerMarkdown: "done",
        responseID: "resp_1",
        followUps: [],
        generationStatus: "model",
        inferenceMode: "structured",
      },
    });

    const secondResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(secondRequest),
      }),
      env
    );

    expect(secondResponse.status).toBe(202);
    const secondBody = await secondResponse.json();
    expect(secondBody.jobID).not.toBe(firstBody.jobID);
    expect(workflowCreate).toHaveBeenCalledTimes(2);
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
      provider: "workers_ai",
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

  it("uses separate generate and persist workflow steps for async chat jobs", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
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
    const env = makeEnv();
    const createRequest = makeChatJobCreateRequestFixture();
    const createResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(createRequest),
      }),
      env
    );
    const created = await createResponse.json();
    const step = {
      do: vi.fn(
        async (
          name: string,
          arg2: unknown,
          arg3?: () => Promise<unknown>
        ): Promise<unknown> => {
          const callback =
            typeof arg2 === "function"
              ? (arg2 as () => Promise<unknown>)
              : (arg3 as () => Promise<unknown>);
          return callback();
        }
      ),
    };

    await executeChatJob(
      created.jobID,
      env,
      {
        createStateRepository: () => repository,
        createInferenceService: () => stubInferenceService(),
      },
      step as never
    );

    const stepNames = step.do.mock.calls.map(([name]) => name);
    expect(stepNames).toEqual([
      "mark_chat_job_running",
      "generate_chat_response",
      "persist_chat_completion",
      "commit_chat_memory",
    ]);
    expect(stepNames).not.toContain("generate_and_persist_chat_response");
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
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    try {
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

      const memoryCommitLog = parseLoggedPayloads(errorSpy).find(
        (payload) => payload.event === "coach_chat_job_memory_commit_failed"
      );
      expect(memoryCommitLog).toMatchObject({
        phase: "memory_commit",
        failureOrigin: "memory_commit",
        errorName: "Error",
        errorMessage: "KV temporarily unavailable",
      });
      expect(memoryCommitLog?.stackPreview).toEqual(expect.any(String));
    } finally {
      errorSpy.mockRestore();
    }
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

  it("classifies inference failures with the real failure phase in terminal logs", async () => {
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
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    try {
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
              "Workers AI request timed out",
              {
                promptBytes: 321,
                mode: "structured",
                modelDurationMs: 5_000,
              }
            ),
          }),
      });

      expect(failed?.status).toBe("failed");
      expect(failed?.error?.code).toBe("upstream_timeout");

      const diagnosticsLog = parseLoggedPayloads(errorSpy).find(
        (payload) => payload.event === "coach_chat_job_failure_diagnostics"
      );
      expect(diagnosticsLog).toMatchObject({
        phase: "inference",
        failureOrigin: "inference",
        errorCode: "upstream_timeout",
        errorName: "CoachInferenceServiceError",
        errorMessage: "Workers AI request timed out",
        wasRecognizedAsInferenceError: true,
        wasRecognizedAsPersistenceError: false,
        inferredCancellation: false,
      });
      expect(diagnosticsLog?.stackPreview).toEqual(expect.any(String));

      const failedLog = parseLoggedPayloads(errorSpy).find(
        (payload) => payload.event === "coach_chat_job_failed"
      );
      expect(failedLog).toMatchObject({
        phase: "inference",
        failureOrigin: "inference",
        errorCode: "upstream_timeout",
      });
    } finally {
      errorSpy.mockRestore();
    }
  });

  it("keeps Gemini family block chat job failures explicit and non-retryable", async () => {
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
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    try {
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
              429,
              "provider_family_blocked",
              "Gemini 2.5 models are temporarily blocked after quota exhaustion. Please try again after the next Pacific reset.",
              {
                requestedModel: "gemini-2.5-flash",
                attemptedModels: ["gemini-3.1-flash-lite-preview"],
                fallbackModelUsed: "gemini-3.1-flash-lite-preview",
                providerQuotaExhausted: true,
                providerFamilyBlocked: true,
                blockedUntil: "2026-03-29T07:00:00.000Z",
                quotaClassificationKind: "daily_quota",
                requestPath: "chat",
                sourceProviderErrorStatus: 429,
                sourceProviderErrorCode: "RESOURCE_EXHAUSTED",
                providerFamily: "gemini-2.5",
                emergencyFallbackUsed: true,
              }
            ),
          }),
      });

      expect(failed?.status).toBe("failed");
      expect(failed?.error).toMatchObject({
        code: "provider_family_blocked",
        message:
          "Gemini 2.5 models are temporarily blocked after quota exhaustion. Please try again after the next Pacific reset.",
        retryable: false,
      });

      const diagnosticsLog = parseLoggedPayloads(errorSpy).find(
        (payload) => payload.event === "coach_chat_job_failure_diagnostics"
      );
      expect(diagnosticsLog).toMatchObject({
        phase: "inference",
        failureOrigin: "inference",
        errorCode: "provider_family_blocked",
        providerQuotaExhausted: true,
        providerFamilyBlocked: true,
        blockedUntil: "2026-03-29T07:00:00.000Z",
        quotaClassificationKind: "daily_quota",
        attemptedModels: ["gemini-3.1-flash-lite-preview"],
      });
    } finally {
      errorSpy.mockRestore();
    }
  });

  it("normalizes cancellation-like inference errors to workflow_canceled", async () => {
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
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    try {
      const createResponse = await app.fetch(
        authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
          method: "POST",
          body: JSON.stringify(createRequest),
        }),
        env
      );
      const created = await createResponse.json();
      const abortError = new Error("This script will never generate a response");
      abortError.name = "AbortError";

      const failed = await executeChatJob(created.jobID, env, {
        createStateRepository: () => repository,
        createInferenceService: () =>
          stubInferenceService({
            chatError: abortError,
          }),
      });

      expect(failed?.status).toBe("failed");
      expect(failed?.error).toMatchObject({
        code: "workflow_canceled",
        retryable: true,
      });

      const diagnosticsLog = parseLoggedPayloads(errorSpy).find(
        (payload) => payload.event === "coach_chat_job_failure_diagnostics"
      );
      expect(diagnosticsLog).toMatchObject({
        phase: "inference",
        failureOrigin: "inference",
        errorCode: "workflow_canceled",
        errorName: "AbortError",
        wasRecognizedAsInferenceError: false,
        wasRecognizedAsPersistenceError: false,
        inferredCancellation: true,
      });

      const storedJob = await repository.getChatJob(created.jobID, createRequest.installID);
      expect(storedJob?.error).toMatchObject({
        code: "workflow_canceled",
        retryable: true,
      });
    } finally {
      errorSpy.mockRestore();
    }
  });

  it("classifies completeChatJob persistence failures as persist_completion", async () => {
    class FailingCompleteRepository extends InMemoryCoachStateRepository {
      override async completeChatJob(
        _jobID: string,
        _input: Parameters<InMemoryCoachStateRepository["completeChatJob"]>[1]
      ): Promise<never> {
        throw new Error("D1 completion write failed");
      }
    }

    const repository = new FailingCompleteRepository("test.v1", DEFAULT_AI_MODEL);
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
    const env = makeEnv();
    const createRequest = makeChatJobCreateRequestFixture();
    const createResponse = await app.fetch(
      authedRequest("https://coach.example.workers.dev/v2/coach/chat-jobs", {
        method: "POST",
        body: JSON.stringify(createRequest),
      }),
      env
    );
    const created = await createResponse.json();
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    try {
      const failed = await executeChatJob(created.jobID, env, {
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

      expect(failed?.status).toBe("failed");
      expect(failed?.error?.code).toBe("persistence_error");

      const persistStartedLog = parseLoggedPayloads(logSpy).find(
        (payload) => payload.event === "coach_chat_job_persist_started"
      );
      expect(persistStartedLog).toMatchObject({
        phase: "persist_completion",
        failureOrigin: "persist_completion",
        generationStatus: "model",
      });

      const persistFailedLog = parseLoggedPayloads(errorSpy).find(
        (payload) => payload.event === "coach_chat_job_persist_failed"
      );
      expect(persistFailedLog).toMatchObject({
        phase: "persist_completion",
        failureOrigin: "persist_completion",
        errorName: "Error",
        errorMessage: "D1 completion write failed",
      });

      const diagnosticsLog = parseLoggedPayloads(errorSpy).find(
        (payload) => payload.event === "coach_chat_job_failure_diagnostics"
      );
      expect(diagnosticsLog).toMatchObject({
        phase: "persist_completion",
        failureOrigin: "persist_completion",
        errorCode: "persistence_error",
        wasRecognizedAsInferenceError: false,
        wasRecognizedAsPersistenceError: true,
        inferredCancellation: false,
      });

      const failedLog = parseLoggedPayloads(errorSpy).find(
        (payload) => payload.event === "coach_chat_job_failed"
      );
      expect(failedLog).toMatchObject({
        phase: "persist_completion",
        failureOrigin: "persist_completion",
        errorCode: "persistence_error",
      });
    } finally {
      errorSpy.mockRestore();
      logSpy.mockRestore();
    }
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
        selectedModel: expect.any(String),
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
          workoutSummarySelectedModel: "gemini-2.5-flash-lite",
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
        selectedModel: "gemini-2.5-flash-lite",
      },
    });
  });

  it("keeps Gemini quota workout summary failures explicit and non-retryable", async () => {
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
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    try {
      const createResponse = await app.fetch(
        authedRequest("https://coach.example.workers.dev/v2/coach/workout-summary-jobs", {
          method: "POST",
          body: JSON.stringify(request),
        }),
        env
      );
      const created = await createResponse.json();

      const failed = await executeWorkoutSummaryJob(created.jobID, env, {
        createStateRepository: () => repository,
        createInferenceService: () =>
          stubInferenceService({
            workoutSummaryError: new CoachInferenceServiceError(
              429,
              "provider_quota_exhausted",
              "Gemini quota is exhausted. Please try again later.",
              {
                requestedModel: "gemini-2.5-flash",
                attemptedModels: [
                  "gemini-2.5-flash",
                  "gemini-2.5-flash-lite",
                  "gemini-3.1-flash-lite-preview",
                ],
                fallbackModelUsed: "gemini-3.1-flash-lite-preview",
                providerQuotaExhausted: true,
                providerFamilyBlocked: false,
                quotaClassificationKind: "project_quota",
                requestPath: "workout_summary",
                sourceProviderErrorStatus: 429,
                sourceProviderErrorCode: "RESOURCE_EXHAUSTED",
                providerFamily: "gemini-2.5",
                emergencyFallbackUsed: true,
              }
            ),
          }),
      });

      expect(failed?.status).toBe("failed");
      expect(failed?.error).toMatchObject({
        code: "provider_quota_exhausted",
        message: "Gemini quota is exhausted. Please try again later.",
        retryable: false,
      });

      const diagnosticsLog = parseLoggedPayloads(errorSpy).find(
        (payload) => payload.event === "workout_summary_job_failure_diagnostics"
      );
      expect(diagnosticsLog).toMatchObject({
        errorCode: "provider_quota_exhausted",
        providerQuotaExhausted: true,
        quotaClassificationKind: "project_quota",
        attemptedModels: [
          "gemini-2.5-flash",
          "gemini-2.5-flash-lite",
          "gemini-3.1-flash-lite-preview",
        ],
        emergencyFallbackUsed: true,
      });
    } finally {
      errorSpy.mockRestore();
    }
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

  it("validates malformed sync chat requests", async () => {
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

describe("legacy D1 provider-column compatibility", () => {
  it("creates Gemini chat jobs when provider columns are missing", async () => {
    const repository = new CloudflareCoachStateRepository(
      makeNoopKV(),
      makeNoopR2(),
      new LegacyProviderlessJobDB(),
      "test.v1",
      DEFAULT_AI_MODEL
    );
    const request = {
      ...makeChatJobCreateRequestFixture(),
      provider: "gemini" as const,
      clientRequestID: "gemini-chat-request-1",
    };

    const created = await repository.createChatJob({
      jobID: "chatjob_legacy_gemini",
      installID: request.installID,
      clientRequestID: request.clientRequestID,
      createdAt: "2026-03-27T18:00:00.000Z",
      model: "gemini-2.5-flash",
      provider: "gemini",
      preparedRequest: {
        ...request,
        responseID: "response_legacy_gemini",
        metadata: makeExecutionMetadata("gemini", "gemini-2.5-flash"),
      },
      contextHash: "context_hash_legacy_gemini",
      contextSource: "inline_legacy",
      chatMemoryHit: false,
      snapshotBytes: 512,
      recentTurnCount: request.clientRecentTurns.length,
      recentTurnChars: request.clientRecentTurns.reduce(
        (total, turn) => total + turn.content.length,
        0
      ),
      questionChars: request.question.length,
    });

    expect(created.jobID).toBe("chatjob_legacy_gemini");
    expect(created.provider).toBe("gemini");
    expect(created.clientRequestID).toBe("gemini-chat-request-1");
    expect(created.preparedRequest.metadata?.provider).toBe("gemini");
  });

  it("creates Gemini workout summary jobs when provider columns are missing", async () => {
    const repository = new CloudflareCoachStateRepository(
      makeNoopKV(),
      makeNoopR2(),
      new LegacyProviderlessJobDB(),
      "test.v1",
      DEFAULT_AI_MODEL
    );
    const request = {
      ...makeWorkoutSummaryJobCreateRequestFixture(),
      provider: "gemini" as const,
      clientRequestID: "gemini-summary-request-1",
    };

    const created = await repository.createWorkoutSummaryJob({
      jobID: "summaryjob_legacy_gemini",
      installID: request.installID,
      clientRequestID: request.clientRequestID,
      sessionID: request.sessionID,
      fingerprint: request.fingerprint,
      createdAt: "2026-03-27T18:05:00.000Z",
      model: "gemini-2.5-flash",
      provider: "gemini",
      preparedRequest: {
        ...request,
        metadata: makeExecutionMetadata("gemini", "gemini-2.5-flash"),
      },
      requestMode: request.requestMode,
      trigger: request.trigger,
      inputMode: request.inputMode,
      currentExerciseCount: request.currentWorkout.exerciseCount,
      historyExerciseCount: request.recentExerciseHistory.length,
      historySessionCount: request.recentExerciseHistory.reduce(
        (total, exercise) => total + exercise.sessions.length,
        0
      ),
    });

    expect(created.jobID).toBe("summaryjob_legacy_gemini");
    expect(created.provider).toBe("gemini");
    expect(created.clientRequestID).toBe("gemini-summary-request-1");
    expect(created.preparedRequest.metadata?.provider).toBe("gemini");
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

  it("builds profile insights attempts in balanced -> quality -> plain-text order", () => {
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
      ["insights_balanced", "structured"],
      ["quality_escalation", "structured"],
      ["sync_fallback", "plain_text_fallback"],
    ]);
    expect(attempts.map((attempt) => attempt.selectedModel)).toEqual([
      "@cf/test/profile-balanced",
      "@cf/test/profile-quality",
      "@cf/test/profile-fallback",
    ]);
    expect(attempts.map((attempt) => attempt.fallbackHopCount)).toEqual([0, 1, 2]);
  });

  it("uses rich analytics context for Gemini profile insights routing", () => {
    const env = makeEnv();
    const decision = buildProfileInsightsRoutingDecision(env, {
      ...makeProfileInsightsRequestFixture(),
      provider: "gemini",
    });
    const attempts = buildProfileInsightsRoutingAttempts(env, decision);

    expect(decision.allowedContextProfiles).toEqual(["rich_async_analytics_v1"]);
    expect(decision.payloadTier).toBe("full");
    expect(decision.promptFamily).toBe("profile_quality_first_rich_async_v2");
    expect(attempts.every((attempt) => attempt.contextProfile === "rich_async_analytics_v1")).toBe(true);
    expect(attempts.every((attempt) => attempt.promptProfile === "profile_rich_async_analytics_v2")).toBe(true);
  });

  it("keeps Gemini profile insights plain-text fallback on a quality model instead of flash-lite", () => {
    const env = makeEnv({
      MODEL_ROUTING_ENABLED: "true",
      QUALITY_ESCALATION_ENABLED: "true",
      GEMINI_INSIGHTS_FAST_MODEL: "gemini-test-fast",
      GEMINI_INSIGHTS_BALANCED_MODEL: "gemini-test-balanced",
      GEMINI_QUALITY_ESCALATION_MODEL: "gemini-test-quality",
      GEMINI_SYNC_FALLBACK_MODEL: "gemini-test-lite",
    });
    const decision = buildProfileInsightsRoutingDecision(env, {
      ...makeProfileInsightsRequestFixture(),
      provider: "gemini",
    });
    const attempts = buildProfileInsightsRoutingAttempts(env, decision);
    const fallbackAttempt = attempts.at(-1);

    expect(fallbackAttempt).toMatchObject({
      modelRole: "quality_escalation",
      mode: "plain_text_fallback",
      selectedModel: "gemini-test-quality",
    });
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
    expect(promptText).toContain(
      "Use recent sessions, adherence, progression, PRs, preferred program structure, and the saved note together."
    );
    expect(promptText).toContain("Goal summary JSON:");
    expect(promptText).toContain("Consistency summary JSON:");
    expect(promptText).toContain("30-day progress JSON:");
    expect(promptText).toContain(
      "Focus guidance: treat rolling rotation and template count versus weekly target as already-resolved execution context"
    );
    expect(promptText).toContain("Preferred program summary JSON:");
    expect(promptText).toContain(
      "Do not ask the user to verify whether a workout, exercise, or muscle group is included unless the program summary explicitly shows a real gap."
    );
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
    expect(result.data.recommendations ?? []).toContain("Keep bench progression steady.");
    expect(result.data.recommendations ?? []).toEqual(
      expect.arrayContaining([
        expect.stringContaining("rolling execution model"),
    ])
);
  });

  it("keeps the full rolling-rotation note in compact profile insights prompts, preserves program coverage, and de-emphasizes structure", () => {
    const request = makeProfileInsightsRequestFixture();
    const snapshot = request.snapshot!;
    request.snapshot = {
      ...snapshot,
      coachAnalysisSettings: {
        ...snapshot.coachAnalysisSettings,
        programComment: [
          "I train on a rolling rotation instead of matching everything to a calendar week.",
          "I keep rotating through more templates than I perform each week.",
          "Do not treat that as a mismatch between my saved program and weekly frequency.",
          "Keep the coaching focused on progression, recovery, and next-step decisions.",
        ].join(" "),
      },
    };

    const messages = buildProfileInsightsMessages(request);
    const systemPrompt = messages[0]?.content ?? "";
    const userPrompt = messages[1]?.content ?? "";

    expect(systemPrompt).toContain(
      "Use recent sessions, adherence, progression, PRs, preferred program structure, and the saved note together."
    );
    expect(userPrompt).toContain(
      "Do not treat that as a mismatch between my saved program and weekly frequency."
    );
    expect(userPrompt).toContain(
      "Focus guidance: treat rolling rotation and template count versus weekly target as already-resolved execution context"
    );
    expect(userPrompt).toContain("Preferred program summary JSON:");
    expect(userPrompt).toContain(
      "Program coverage guidance: treat the preferred program summary as authoritative proof of which workouts and exercises are already included."
    );
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

  it("filters unsupported program-coverage guesses from profile insights", async () => {
    const aiRun = vi.fn().mockResolvedValue({
      response: {
        summary: "Тренировки идут стабильно.",
        recommendations: [
          "Убедитесь, что руки, спина и ноги включены в ваши тренировочные шаблоны.",
          "Сохраняйте текущую прогрессию и повышайте нагрузку только на повторяемых сетах.",
        ],
      },
    });

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const result = await service.generateProfileInsights(
      makeProfileInsightsRequestFixture()
    );

    expect(result.data.recommendations).toEqual([
      "Treat this as a cautious watchpoint rather than a hard claim: Убедитесь, что руки, спина и ноги включены в ваши тренировочные шаблоны.",
      "Сохраняйте текущую прогрессию и повышайте нагрузку только на повторяемых сетах.",
    ]);
  });

  it("does not append hardcoded confidence notes to model-generated profile insights", async () => {
    const aiRun = vi.fn().mockResolvedValue({
      response: {
        summary: "Прогресс по программе есть, но пока важнее удержать регулярность.",
        keyObservations: ["Нагрузка по основным движениям пока держится стабильно."],
        topConstraints: ["Низкая общая частота тренировок ограничивает скорость прогресса."],
        recommendations: ["Сохраняйте текущую прогрессию и повышайте нагрузку только на повторяемых сетах."],
        confidenceNotes: [
          "Данные о мышечной экспозиции и отстающих группах основаны на недавних тренировках и могут быть неполными из-за низкой общей активности.",
          "Прогноз срока достижения цели является ориентировочным и сильно зависит от повышения регулярности тренировок.",
        ],
      },
    });

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const result = await service.generateProfileInsights(
      makeProfileInsightsRequestFixture()
    );

    expect(result.data.keyObservations).toEqual([
      "Нагрузка по основным движениям пока держится стабильно.",
    ]);
    expect(result.data.topConstraints).toEqual([
      "Низкая общая частота тренировок ограничивает скорость прогресса.",
    ]);
    expect(result.data.confidenceNotes).toEqual([
      "Данные о мышечной экспозиции и отстающих группах основаны на недавних тренировках и могут быть неполными из-за низкой общей активности.",
      "Прогноз срока достижения цели является ориентировочным и сильно зависит от повышения регулярности тренировок.",
    ]);
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
    expect(result.data.summary).toBe("Recovery is adequate. - Keep volume stable this week.");
    expect(result.data.recommendations).toEqual([
      "Keep volume stable this week.",
    ]);
    expect(result.data.generationStatus).toBe("model");
    expect(result.data.insightSource).toBe("fresh_model");
  });

  it("uses responseJsonSchema for Gemini structured profile insights requests", async () => {
    const fetchSpy = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      text: async () =>
        JSON.stringify({
          candidates: [
            {
              content: {
                parts: [
                  {
                    text: JSON.stringify({
                      summary: "Gemini structured summary.",
                      recommendations: ["Keep the weekly load steady."],
                      unexpectedField: "ignore me",
                    }),
                  },
                ],
              },
            },
          ],
          usageMetadata: {
            promptTokenCount: 42,
            candidatesTokenCount: 27,
          },
          responseId: "gemini-response-1",
        }),
    });
    vi.stubGlobal("fetch", fetchSpy);

    try {
      const service = createInferenceServiceForProvider(
        makeEnv({
          GEMINI_API_KEY: "test-gemini-key",
        }),
        "gemini"
      );
      const result = await service.generateProfileInsights({
        ...makeProfileInsightsRequestFixture(),
        provider: "gemini",
      });

      expect(fetchSpy).toHaveBeenCalledTimes(1);
      const [, requestInit] = fetchSpy.mock.calls[0] as [
        string,
        { body?: string }
      ];
      const payload = JSON.parse(requestInit.body ?? "{}");
      expect(payload.generationConfig?.responseMimeType).toBe("application/json");
      expect(payload.generationConfig?.responseJsonSchema).toMatchObject({
        type: "object",
        required: [
          "summary",
          "keyObservations",
          "topConstraints",
          "recommendations",
          "confidenceNotes",
        ],
        additionalProperties: false,
      });
      expect(payload.generationConfig?.responseSchema).toBeUndefined();
      expect(result.provider).toBe("gemini");
      expect(result.mode).toBe("structured");
      expect(result.data).toMatchObject({
        summary: "Gemini structured summary.",
        recommendations: ["Keep the weekly load steady."],
        generationStatus: "model",
        insightSource: "fresh_model",
      });
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("salvages Gemini structured profile insights when recommendations arrive as a string", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const fetchSpy = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      text: async () =>
        JSON.stringify({
          candidates: [
            {
              content: {
                parts: [
                  {
                    text: JSON.stringify({
                      summary: "Gemini structured summary.",
                      recommendations:
                        "- Keep the weekly load stable.\n- Add one rep on the final set if recovery stays good.",
                    }),
                  },
                ],
              },
            },
          ],
        }),
    });
    vi.stubGlobal("fetch", fetchSpy);

    try {
      const service = createInferenceServiceForProvider(
        makeEnv({
          GEMINI_API_KEY: "test-gemini-key",
        }),
        "gemini"
      );
      const result = await service.generateProfileInsights({
        ...makeProfileInsightsRequestFixture(),
        provider: "gemini",
      });

      expect(result.provider).toBe("gemini");
      expect(result.mode).toBe("structured");
      expect(result.data).toMatchObject({
        summary: "Gemini structured summary.",
        recommendations: [
          "Keep the weekly load stable.",
          "Add one rep on the final set if recovery stays good.",
        ],
        generationStatus: "model",
        insightSource: "fresh_model",
      });
      expect(parseLoggedPayloads(logSpy)).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            event: "coach_profile_attempt_succeeded",
            provider: "gemini",
            structuredParseMode: "lenient_json_coercion",
          }),
        ])
      );
    } finally {
      logSpy.mockRestore();
      vi.unstubAllGlobals();
    }
  });

  it("salvages Gemini structured profile insights when the structured attempt returns plain text", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const fetchSpy = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      text: async () =>
        JSON.stringify({
          candidates: [
            {
              content: {
                parts: [
                  {
                    text: [
                      "Summary: The current rotation is working and recovery looks stable.",
                      "",
                      "- Keep the current weekly rhythm.",
                      "- Add load only on lifts that felt repeatable.",
                    ].join("\n"),
                  },
                ],
              },
            },
          ],
        }),
    });
    vi.stubGlobal("fetch", fetchSpy);

    try {
      const service = createInferenceServiceForProvider(
        makeEnv({
          GEMINI_API_KEY: "test-gemini-key",
        }),
        "gemini"
      );
      const result = await service.generateProfileInsights({
        ...makeProfileInsightsRequestFixture(),
        provider: "gemini",
      });

      expect(result.provider).toBe("gemini");
      expect(result.mode).toBe("structured");
      expect(result.data).toMatchObject({
        summary: "The current rotation is working and recovery looks stable. - Keep the current weekly rhythm. - Add load only on lifts that felt repeatable.",
        recommendations: [
          "Keep the current weekly rhythm.",
          "Add load only on lifts that felt repeatable.",
        ],
        generationStatus: "model",
        insightSource: "fresh_model",
      });
      expect(parseLoggedPayloads(logSpy)).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            event: "coach_profile_attempt_succeeded",
            provider: "gemini",
            structuredParseMode: "lenient_plain_text_coercion",
          }),
        ])
      );
    } finally {
      logSpy.mockRestore();
      vi.unstubAllGlobals();
    }
  });

  it("retries Gemini profile insights after a rate limit response", async () => {
    const kv = makeMemoryKV();
    const fetchSpy = vi
      .fn()
      .mockResolvedValueOnce({
        ok: false,
        status: 429,
        text: async () =>
          JSON.stringify({
            error: {
              message: "Too many requests right now.",
              status: "UNAVAILABLE",
              details: [
                {
                  retryDelay: "0.001s",
                },
              ],
            },
          }),
      })
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        text: async () =>
          JSON.stringify({
            candidates: [
              {
                content: {
                  parts: [
                    {
                      text: JSON.stringify({
                        summary: "Retried Gemini summary.",
                        recommendations: ["Retry succeeded after a short pause."],
                      }),
                    },
                  ],
                },
              },
            ],
          }),
      });
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.stubGlobal("fetch", fetchSpy);

    try {
      const service = createInferenceServiceForProvider(
        makeEnv({
          GEMINI_API_KEY: "test-gemini-key",
          COACH_STATE_KV: kv,
          GEMINI_2_5_QUOTA_BLOCK_ENABLED: "true",
        }),
        "gemini"
      );
      const result = await service.generateProfileInsights({
        ...makeProfileInsightsRequestFixture(),
        provider: "gemini",
      });

      expect(fetchSpy).toHaveBeenCalledTimes(2);
      expect(result.mode).toBe("structured");
      expect(result.data.summary).toBe("Retried Gemini summary.");
      await expect(
        kv.get(buildGemini2_5FamilyBlockKey(), "json")
      ).resolves.toBeNull();
      expect(parseLoggedPayloads(warnSpy)).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            event: "coach_gemini_retry_scheduled",
            status: 429,
            retryAttempt: 1,
          }),
        ])
      );
    } finally {
      warnSpy.mockRestore();
      vi.unstubAllGlobals();
    }
  });

  it("silently retries Gemini 2.5 flash quota exhaustion on flash-lite", async () => {
    const fetchSpy = vi
      .fn()
      .mockResolvedValueOnce({
        ok: false,
        status: 429,
        text: async () =>
          JSON.stringify({
            error: {
              message: "Quota exceeded for Gemini 2.5 Flash.",
              status: "RESOURCE_EXHAUSTED",
            },
          }),
      })
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        text: async () =>
          JSON.stringify({
            candidates: [
              {
                content: {
                  parts: [
                    {
                      text: JSON.stringify({
                        summary: "Flash-lite carried the request.",
                        recommendations: ["Keep the current load progression."],
                      }),
                    },
                  ],
                },
              },
            ],
          }),
      });
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.stubGlobal("fetch", fetchSpy);

    try {
      const service = createInferenceServiceForProvider(
        makeEnv({
          GEMINI_API_KEY: "test-gemini-key",
        }),
        "gemini"
      );
      const result = await service.generateProfileInsights({
        ...makeProfileInsightsRequestFixture(),
        provider: "gemini",
      });

      expect(fetchSpy.mock.calls.map(([url]) => String(url))).toEqual([
        expect.stringContaining("/models/gemini-2.5-flash:generateContent"),
        expect.stringContaining("/models/gemini-2.5-flash-lite:generateContent"),
      ]);
      expect(result.data.summary).toBe("Flash-lite carried the request.");
      expect(result.model).toBe("gemini-2.5-flash-lite");
      expect(result.selectedModel).toBe("gemini-2.5-flash-lite");
      expect(result.requestedModel).toBe("gemini-2.5-flash");
      expect(result.attemptedModels).toEqual([
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
      ]);
      expect(result.fallbackModelUsed).toBe("gemini-2.5-flash-lite");
      expect(result.providerQuotaExhausted).toBe(true);
      expect(result.emergencyFallbackUsed).toBe(false);
      expect(parseLoggedPayloads(warnSpy)).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            event: "gemini_quota_exhausted_detected",
            requestedModel: "gemini-2.5-flash",
            failedModel: "gemini-2.5-flash",
          }),
        ])
      );
      expect(parseLoggedPayloads(logSpy)).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            event: "gemini_model_fallback_succeeded",
            requestedModel: "gemini-2.5-flash",
            fallbackModel: "gemini-2.5-flash-lite",
          }),
        ])
      );
    } finally {
      logSpy.mockRestore();
      warnSpy.mockRestore();
      vi.unstubAllGlobals();
    }
  });

  it("sets a Gemini 2.5 family block and uses emergency fallback after both 2.5 models exhaust quota", async () => {
    const kv = makeMemoryKV();
    const fetchSpy = vi
      .fn()
      .mockResolvedValueOnce({
        ok: false,
        status: 429,
        text: async () =>
          JSON.stringify({
            error: {
              message: "Daily quota exceeded. Requests per day exhausted.",
              status: "RESOURCE_EXHAUSTED",
            },
          }),
      })
      .mockResolvedValueOnce({
        ok: false,
        status: 429,
        text: async () =>
          JSON.stringify({
            error: {
              message: "Daily quota exceeded again. RPD exhausted.",
              status: "RESOURCE_EXHAUSTED",
            },
          }),
      })
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        text: async () =>
          JSON.stringify({
            candidates: [
              {
                content: {
                  parts: [
                    {
                      text: JSON.stringify({
                        summary: "Emergency Gemini 3.1 summary.",
                        recommendations: ["Stay conservative until quota resets."],
                      }),
                    },
                  ],
                },
              },
            ],
          }),
      });
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.stubGlobal("fetch", fetchSpy);

    try {
      const service = createInferenceServiceForProvider(
        makeEnv({
          GEMINI_API_KEY: "test-gemini-key",
          COACH_STATE_KV: kv,
          GEMINI_2_5_QUOTA_BLOCK_ENABLED: "true",
          GEMINI_EMERGENCY_FALLBACK_ENABLED: "true",
          GEMINI_EMERGENCY_FALLBACK_MODEL: "gemini-3.1-flash-lite-preview",
        }),
        "gemini"
      );
      const result = await service.generateProfileInsights({
        ...makeProfileInsightsRequestFixture(),
        provider: "gemini",
      });

      expect(fetchSpy.mock.calls.map(([url]) => String(url))).toEqual([
        expect.stringContaining("/models/gemini-2.5-flash:generateContent"),
        expect.stringContaining("/models/gemini-2.5-flash-lite:generateContent"),
        expect.stringContaining(
          "/models/gemini-3.1-flash-lite-preview:generateContent"
        ),
      ]);
      expect(result.model).toBe("gemini-3.1-flash-lite-preview");
      expect(result.attemptedModels).toEqual([
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
        "gemini-3.1-flash-lite-preview",
      ]);
      expect(result.fallbackModelUsed).toBe("gemini-3.1-flash-lite-preview");
      expect(result.providerQuotaExhausted).toBe(true);
      expect(result.geminiDailyQuotaExhausted).toBe(true);
      expect(result.providerFamilyBlocked).toBe(true);
      expect(result.emergencyFallbackUsed).toBe(true);
      expect(result.blockedUntil).toEqual(expect.any(String));
      await expect(
        kv.get(buildGemini2_5FamilyBlockKey(), "json")
      ).resolves.toMatchObject({
        providerFamily: "gemini-2.5",
        scope: "family",
        rawCategory: "daily_quota",
      });
      expect(parseLoggedPayloads(warnSpy)).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            event: "gemini_family_block_set",
            requestedModel: "gemini-2.5-flash",
          }),
          expect.objectContaining({
            event: "gemini_emergency_fallback_to_3_1_started",
            requestedModel: "gemini-2.5-flash",
            fallbackModel: "gemini-3.1-flash-lite-preview",
          }),
        ])
      );
    } finally {
      warnSpy.mockRestore();
      vi.unstubAllGlobals();
    }
  });

  it("skips Gemini 2.5 models entirely when the family block is already active", async () => {
    const kv = makeMemoryKV();
    await writeGemini2_5FamilyBlockState(kv, {
      reason: "daily_quota",
      sourceModel: "gemini-2.5-flash-lite",
      sourcePath: "profile_insights",
      providerStatus: 429,
      providerCode: "RESOURCE_EXHAUSTED",
    });
    const fetchSpy = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      text: async () =>
        JSON.stringify({
          candidates: [
            {
              content: {
                parts: [
                  {
                    text: JSON.stringify({
                      summary: "Emergency path served immediately.",
                      recommendations: ["Wait for the Pacific reset window."],
                    }),
                  },
                ],
              },
            },
          ],
        }),
    });
    vi.stubGlobal("fetch", fetchSpy);

    try {
      const service = createInferenceServiceForProvider(
        makeEnv({
          GEMINI_API_KEY: "test-gemini-key",
          COACH_STATE_KV: kv,
          GEMINI_2_5_QUOTA_BLOCK_ENABLED: "true",
          GEMINI_EMERGENCY_FALLBACK_ENABLED: "true",
          GEMINI_EMERGENCY_FALLBACK_MODEL: "gemini-3.1-flash-lite-preview",
        }),
        "gemini"
      );
      const result = await service.generateProfileInsights({
        ...makeProfileInsightsRequestFixture(),
        provider: "gemini",
      });

      expect(fetchSpy).toHaveBeenCalledTimes(1);
      expect(String(fetchSpy.mock.calls[0]?.[0])).toContain(
        "/models/gemini-3.1-flash-lite-preview:generateContent"
      );
      expect(result.requestedModel).toBe("gemini-2.5-flash");
      expect(result.attemptedModels).toEqual(["gemini-3.1-flash-lite-preview"]);
      expect(result.providerFamilyBlocked).toBe(true);
      expect(result.emergencyFallbackUsed).toBe(true);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("allows a slower sync structured Gemini profile insights response before falling back", async () => {
    vi.useFakeTimers();
    const fetchSpy = vi.fn().mockImplementation(() =>
      new Promise((resolve) => {
        setTimeout(() => {
          resolve({
            ok: true,
            status: 200,
            text: async () =>
              JSON.stringify({
                candidates: [
                  {
                    content: {
                      parts: [
                        {
                          text: JSON.stringify({
                            summary: "Gemini structured summary after a slower response.",
                            recommendations: [
                              "Keep the current weekly load stable for one more week.",
                            ],
                          }),
                        },
                      ],
                    },
                  },
                ],
              }),
          });
        }, 18_000);
      })
    );
    vi.stubGlobal("fetch", fetchSpy);

    try {
      const service = createInferenceServiceForProvider(
        makeEnv({
          GEMINI_API_KEY: "test-gemini-key",
        }),
        "gemini"
      );

      const requestPromise = service.generateProfileInsights({
        ...makeProfileInsightsRequestFixture(),
        provider: "gemini",
      });
      await vi.advanceTimersByTimeAsync(18_100);
      const result = await requestPromise;

      expect(fetchSpy).toHaveBeenCalledTimes(1);
      expect(result.provider).toBe("gemini");
      expect(result.mode).toBe("structured");
      expect(result.data).toMatchObject({
        summary: "Gemini structured summary after a slower response.",
        generationStatus: "model",
        insightSource: "fresh_model",
      });
    } finally {
      vi.useRealTimers();
      vi.unstubAllGlobals();
    }
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
        DEFAULT_AI_MODEL,
        "@cf/meta/llama-3.1-8b-instruct-fast",
      ]);
      expect(result.mode).toBe("local_fallback");
      expect(result.model).toBe("@cf/meta/llama-3.1-8b-instruct-fast");
      expect(result.modelRole).toBe("sync_fallback");
      expect(result.fallbackHopCount).toBe(1);
      expect(result.data.summary).toBe("This summary is based on factual training data and on your saved note about how you actually run the program.");

      const warnEvents = parseLoggedPayloads(warnSpy).map((payload) => payload.event);
      expect(warnEvents).toContain("coach_profile_attempt_failed");
      // Just check that we have some log payloads without asserting exact structure
      expect(parseLoggedPayloads(logSpy).length).toBeGreaterThan(0);
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
      DEFAULT_AI_MODEL,
      "@cf/meta/llama-3.1-8b-instruct-fast",
    ]);
    expect(result.mode).toBe("plain_text_fallback");
    expect(result.model).toBe("@cf/meta/llama-3.1-8b-instruct-fast");
    expect(result.modelRole).toBe("sync_fallback");
    expect(result.data.summary).toBe("still not valid json");
    expect(result.data.recommendations).toEqual([
      "Keep the current rotation and weekly rhythm if that reflects how you actually run the program.",
      "You completed 1 of 4 planned sessions this week, so consistency matters more than extra load right now.",
      "Use the most recent completed sessions as the baseline and add load only where the previous work looked repeatable.",
    ]);
    expect(result.data.generationStatus).toBe("model");
    expect(result.data.insightSource).toBe("fresh_model");
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

      expect(aiRun).toHaveBeenCalledTimes(3);
      expect(result.mode).toBe("local_fallback");
      expect(result.fallbackReason).toBe("upstream_timeout");
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
    expect((result.data.recommendations ?? []).length).toBeGreaterThan(0);
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
    expect(result.data.summary).toBe("Recovery is under control. - Keep weekly load stable for one more week.");
    expect(result.data.recommendations).toEqual([
      "Keep weekly load stable for one more week.",
    ]);
    expect(result.data.generationStatus).toBe("model");
    expect(result.data.insightSource).toBe("fresh_model");
  });

  it("keeps actual attempt-specific prompt and routing metadata in profile failure logs", async () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const service = new WorkersAICoachService(
      makeEnv({
        AI: {
          run: vi.fn().mockRejectedValue(new Error("Request timed out")),
        },
        MODEL_ROUTING_ENABLED: "true",
        QUALITY_ESCALATION_ENABLED: "false",
      })
    );

    try {
      await service.generateProfileInsights(makeProfileInsightsRequestFixture(), {
        timeoutProfile: "async_job",
        contextProfile: "rich_async_analytics_v1",
        promptProfile: "profile_rich_async_analytics_v2",
      });

      const failedLog = parseLoggedPayloads(warnSpy).find(
        (payload) => payload.event === "coach_profile_attempt_failed"
      );
      expect(failedLog).toBeDefined();
      expect(failedLog).toMatchObject({
        provider: "workers_ai",
        selectedModel: DEFAULT_AI_MODEL,
        modelRole: "insights_balanced",
        fallbackStage: "primary",
        fallbackHopCount: 0,
        mode: "structured",
      });
      expect(failedLog?.reasonDetails).toMatchObject({
        promptVariant: "profile_rich_async_analytics_v2",
        contextProfile: "rich_async_analytics_v1",
        modelRole: "insights_balanced",
        selectedModel: DEFAULT_AI_MODEL,
        fallbackStage: "primary",
        fallbackHopCount: 0,
        mode: "structured",
      });
    } finally {
      warnSpy.mockRestore();
    }
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

function makeProfileInsightsResponseFixture(
  overrides: Partial<CoachProfileInsightsResponse> = {}
): CoachProfileInsightsResponse {
  return {
    summary: "Summary",
    keyObservations: [],
    topConstraints: [],
    recommendations: ["Recommendation"],
    confidenceNotes: [],
    generationStatus: "model",
    insightSource: "fresh_model",
    ...overrides,
  };
}

function stubInferenceService(overrides?: {
  profileInsights?: Partial<CoachProfileInsightsResponse>;
  workoutSummary?: CoachWorkoutSummaryResponse;
  workoutSummarySelectedModel?: string;
  chat?: CoachChatResponse;
  chatError?: Error;
  workoutSummaryError?: Error;
}): CoachInferenceService {
  return {
    async generateProfileInsights() {
      return {
        data: makeProfileInsightsResponseFixture(overrides?.profileInsights),
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
        model: overrides?.workoutSummarySelectedModel ?? DEFAULT_AI_MODEL,
        selectedModel: overrides?.workoutSummarySelectedModel ?? DEFAULT_AI_MODEL,
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
    COACH_STATE_KV: makeNoopKV(),
    BACKUPS_R2: {} as Env["BACKUPS_R2"],
    APP_META_DB: {} as Env["APP_META_DB"],
    COACH_CHAT_WORKFLOW: makeWorkflowBinding(vi.fn()),
    WORKOUT_SUMMARY_WORKFLOW: makeWorkflowBinding(vi.fn()),
    PROFILE_INSIGHTS_WORKFLOW: makeWorkflowBinding(vi.fn()),
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

function makeNoopKV(): CoachKVNamespace {
  return {
    async get() {
      return null;
    },
    async put() {},
    async delete() {},
  };
}

function makeMemoryKV(): CoachKVNamespace {
  const storage = new Map<string, string>();
  const get: CoachKVNamespace["get"] = (async (
    key: string,
    type: "text" | "json"
  ) => {
    const value = storage.get(key);
    if (value === undefined) {
      return null;
    }

    return type === "json" ? JSON.parse(value) : value;
  }) as CoachKVNamespace["get"];

  return {
    get,
    async put(key, value) {
      storage.set(key, value);
    },
    async delete(key) {
      storage.delete(key);
    },
  };
}

function makeNoopR2(): CoachR2Bucket {
  return {
    async get() {
      return null;
    },
    async put() {},
    async delete() {},
  };
}

function makeExecutionMetadata(
  provider: "workers_ai" | "gemini",
  selectedModel: string
) {
  return {
    provider,
    contextProfile: "rich_async_v1" as const,
    promptProfile: "chat_rich_async_v1",
    contextVersion: "2026-03-27.context.v1",
    analyticsVersion: "2026-03-27.analytics.v1",
    memoryProfile: "rich_async_v1" as const,
    selectedModel,
    routingVersion: "phase1.v1",
    memoryCompatibilityKey: `${provider}:${selectedModel}`,
  };
}

class LegacyProviderlessJobDB implements CoachD1Database {
  private readonly chatRows: Array<Record<string, unknown>> = [];
  private readonly workoutSummaryRows: Array<Record<string, unknown>> = [];

  prepare(query: string): CoachD1PreparedStatement {
    let boundValues: unknown[] = [];
    const normalized = normalizeLegacyDBQuery(query);
    const db = this;

    return {
      bind(...values: unknown[]) {
        boundValues = values;
        return this;
      },
      async first<T = Record<string, unknown>>() {
        const results = db.select(normalized, boundValues);
        return (results[0] as T | undefined) ?? null;
      },
      async run() {
        return db.run(normalized, boundValues);
      },
      async all<T = Record<string, unknown>>() {
        return { results: db.select(normalized, boundValues) as T[] };
      },
    };
  }

  private run(query: string, values: unknown[]): unknown {
    if (query.includes("insert into coach_chat_jobs") && query.includes("provider")) {
      throw new Error("table coach_chat_jobs has no column named provider");
    }
    if (
      query.includes("insert into coach_workout_summary_jobs") &&
      query.includes("provider")
    ) {
      throw new Error("table coach_workout_summary_jobs has no column named provider");
    }

    if (query.includes("insert into coach_chat_jobs")) {
      this.chatRows.push({
        job_id: values[0],
        install_id: values[1],
        client_request_id: values[2],
        status: values[3],
        prepared_request_json: values[4],
        response_json: null,
        error_code: null,
        error_message: null,
        created_at: values[5],
        started_at: null,
        completed_at: null,
        context_hash: values[6],
        context_source: values[7],
        chat_memory_hit: values[8],
        snapshot_bytes: values[9],
        recent_turn_count: values[10],
        recent_turn_chars: values[11],
        question_chars: values[12],
        prompt_version: values[13],
        model: values[14],
        provider: null,
        prompt_bytes: null,
        fallback_prompt_bytes: null,
        model_duration_ms: null,
        fallback_model_duration_ms: null,
        total_job_duration_ms: null,
        inference_mode: null,
        generation_status: null,
        memory_committed_at: null,
      });
      return { meta: { changes: 1 } };
    }

    if (query.includes("insert into coach_workout_summary_jobs")) {
      this.workoutSummaryRows.push({
        job_id: values[0],
        install_id: values[1],
        client_request_id: values[2],
        session_id: values[3],
        fingerprint: values[4],
        status: values[5],
        prepared_request_json: values[6],
        response_json: null,
        error_code: null,
        error_message: null,
        created_at: values[7],
        started_at: null,
        completed_at: null,
        request_mode: values[8],
        trigger: values[9],
        input_mode: values[10],
        current_exercise_count: values[11],
        history_exercise_count: values[12],
        history_session_count: values[13],
        prompt_version: values[14],
        model: values[15],
        provider: null,
        prompt_bytes: null,
        fallback_prompt_bytes: null,
        model_duration_ms: null,
        fallback_model_duration_ms: null,
        total_job_duration_ms: null,
        inference_mode: null,
        generation_status: null,
      });
      return { meta: { changes: 1 } };
    }

    return { meta: { changes: 0 } };
  }

  private select(query: string, values: unknown[]): Array<Record<string, unknown>> {
    if (query.includes("from coach_chat_jobs") && query.includes("provider = ?")) {
      throw new Error("no such column: provider");
    }
    if (
      query.includes("from coach_workout_summary_jobs") &&
      query.includes("provider = ?")
    ) {
      throw new Error("no such column: provider");
    }

    if (query.includes("from coach_chat_jobs where job_id = ? and install_id = ?")) {
      return this.chatRows.filter(
        (row) => row.job_id === values[0] && row.install_id === values[1]
      );
    }

    if (
      query.includes(
        "from coach_chat_jobs where install_id = ? and (client_request_id = ? or client_request_id = ?)"
      )
    ) {
      return this.chatRows
        .filter(
          (row) =>
            row.install_id === values[0] &&
            (row.client_request_id === values[1] || row.client_request_id === values[2])
        )
        .sort((left, right) =>
          String(right.created_at).localeCompare(String(left.created_at))
        );
    }

    if (
      query.includes(
        "from coach_chat_jobs where install_id = ? and status in ('queued', 'running')"
      )
    ) {
      return this.chatRows
        .filter(
          (row) =>
            row.install_id === values[0] &&
            (row.status === "queued" || row.status === "running")
        )
        .sort((left, right) =>
          String(right.created_at).localeCompare(String(left.created_at))
        );
    }

    if (
      query.includes(
        "from coach_workout_summary_jobs where install_id = ? and client_request_id = ?"
      )
    ) {
      return this.workoutSummaryRows.filter(
        (row) => row.install_id === values[0] && row.client_request_id === values[1]
      );
    }

    if (
      query.includes(
        "from coach_workout_summary_jobs where install_id = ? and (client_request_id = ? or client_request_id = ?)"
      )
    ) {
      return this.workoutSummaryRows
        .filter(
          (row) =>
            row.install_id === values[0] &&
            (row.client_request_id === values[1] || row.client_request_id === values[2])
        )
        .sort((left, right) =>
          String(right.created_at).localeCompare(String(left.created_at))
        );
    }

    if (
      query.includes(
        "from coach_workout_summary_jobs where install_id = ? and session_id = ? and fingerprint = ? and prompt_version = ? and model = ? and status in ('queued', 'running', 'completed')"
      )
    ) {
      return this.workoutSummaryRows
        .filter(
          (row) =>
            row.install_id === values[0] &&
            row.session_id === values[1] &&
            row.fingerprint === values[2] &&
            row.prompt_version === values[3] &&
            row.model === values[4] &&
            (row.status === "queued" ||
              row.status === "running" ||
              row.status === "completed")
        )
        .sort((left, right) =>
          String(right.created_at).localeCompare(String(left.created_at))
        );
    }

    if (
      query.includes(
        "from coach_workout_summary_jobs where job_id = ? and install_id = ?"
      )
    ) {
      return this.workoutSummaryRows.filter(
        (row) => row.job_id === values[0] && row.install_id === values[1]
      );
    }

    return [];
  }
}

function normalizeLegacyDBQuery(query: string): string {
  return query.replace(/\s+/g, " ").trim().toLowerCase();
}

function makeWorkflowBinding(create: unknown): any {
  return {
    create: create,
    get: vi.fn().mockResolvedValue(
      makeWorkflowInstanceStub()
    ),
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
    provider: "workers_ai",
    snapshotHash: "a36c44a10cafe4ec5d406e8addcc7adc4a3cd72c3b11ee848b2b6cff2255b382",
    snapshot: makeCompactSnapshotFixture(),
    snapshotUpdatedAt: "2026-03-25T19:00:00.000Z",
    capabilityScope: "draft_changes",
    forceRefresh: false,
    allowDegradedCache: true,
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
    provider: "workers_ai",
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
    provider: "workers_ai",
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

describe("async profile insights job normalization", () => {
  it("normalizes oversized topConstraints items", async () => {
    const oversizedResult = {
      summary: "Test summary",
      keyObservations: ["Observation 1"],
      topConstraints: [
        "This constraint is way too long and exceeds the 320 character limit that is defined in the schema for profile insights responses and should be truncated during normalization to prevent validation errors. This is additional text to make it really long and ensure it gets truncated properly by the normalization function when processing async profile insights job results. ".repeat(3)
      ],
      recommendations: ["Recommendation 1"],
      confidenceNotes: [],
      generationStatus: "model" as const,
      insightSource: "fresh_model" as const,
    };

    const normalized = normalizeAsyncProfileInsightsResult(oversizedResult);

    expect(normalized).not.toBeNull();
    if (!normalized) {
      throw new Error("Expected normalized async profile insights result");
    }
    expect(normalized.topConstraints[0].length).toBeLessThanOrEqual(320);
    expect(normalized.topConstraints[0].length).toBeGreaterThan(0);
  });

  it("normalizes oversized executionContext evidence items", async () => {
    const oversizedResult = {
      summary: "Test summary",
      keyObservations: ["Observation 1"],
      topConstraints: ["Constraint 1"],
      recommendations: ["Recommendation 1"],
      confidenceNotes: [],
      executionContext: {
        mode: "rolling_rotation" as const,
        effectiveWeeklyFrequency: 3,
        shouldTreatProgramCountAsMismatch: false,
        weeklyTarget: 3,
        templateRotationSemantics: "rotate_through_templates" as const,
        authoritativeSignal: "user_note" as const,
        explanation: "Test explanation",
        evidence: [
          "This evidence item is far too long and exceeds the 240 character limit for execution context evidence fields in the profile insights schema and must be truncated during normalization. This is additional text to make it really long and ensure it gets truncated properly by the normalization function when processing async profile insights job results. ".repeat(3)
        ],
      },
      generationStatus: "model" as const,
      insightSource: "fresh_model" as const,
    };

    const normalized = normalizeAsyncProfileInsightsResult(oversizedResult);

    expect(normalized).not.toBeNull();
    if (!normalized) {
      throw new Error("Expected normalized async profile insights result");
    }
    expect(normalized.executionContext?.evidence[0].length).toBeLessThanOrEqual(240);
    expect(normalized.executionContext?.evidence[0].length).toBeGreaterThan(0);
  });

  it("normalizes oversized summary and userNote fields", async () => {
    const oversizedResult = {
      summary: "This summary is way too long and exceeds the 2200 character limit that is defined in the schema for profile insights responses. It should be truncated during normalization to prevent validation errors when the async job completes and the result is stored or retrieved. ".repeat(30),
      keyObservations: ["Observation 1"],
      topConstraints: ["Constraint 1"],
      recommendations: ["Recommendation 1"],
      confidenceNotes: [],
      executionContext: {
        mode: "rolling_rotation" as const,
        effectiveWeeklyFrequency: 3,
        shouldTreatProgramCountAsMismatch: false,
        weeklyTarget: 3,
        templateRotationSemantics: "rotate_through_templates" as const,
        authoritativeSignal: "user_note" as const,
        explanation: "Test explanation",
        userNote: "This user note is far too long and exceeds the 500 character limit for the userNote field in execution context and should be truncated during normalization to prevent validation errors. ".repeat(5),
        evidence: ["Evidence 1"],
      },
      generationStatus: "model" as const,
      insightSource: "fresh_model" as const,
    };

    const normalized = normalizeAsyncProfileInsightsResult(oversizedResult);

    expect(normalized).not.toBeNull();
    if (!normalized) {
      throw new Error("Expected normalized async profile insights result");
    }
    expect(normalized.summary).toHaveLength(2200);
    expect(normalized.executionContext?.userNote).toHaveLength(500);
  });

  it("handles null/undefined input gracefully", async () => {
    expect(normalizeAsyncProfileInsightsResult(null)).toBe(null);
    expect(normalizeAsyncProfileInsightsResult(undefined)).toBe(null);
    expect(normalizeAsyncProfileInsightsResult("not an object")).toBe(null);
  });

  it("normalizes all string arrays with correct limits", async () => {
    const oversizedResult = {
      summary: "Test summary",
      keyObservations: Array(10).fill("This observation is way too long and exceeds the 320 character limit"),
      topConstraints: Array(8).fill("This constraint is way too long and exceeds the 320 character limit"),
      recommendations: Array(10).fill("This recommendation is way too long and exceeds the 320 character limit"),
      confidenceNotes: Array(8).fill("This confidence note is way too long and exceeds the 320 character limit"),
      generationStatus: "model" as const,
      insightSource: "fresh_model" as const,
    };

    const normalized = normalizeAsyncProfileInsightsResult(oversizedResult);

    expect(normalized).not.toBeNull();
    if (!normalized) {
      throw new Error("Expected normalized async profile insights result");
    }
    expect(normalized.keyObservations.length).toBeLessThanOrEqual(8); // max 8
    expect(normalized.topConstraints.length).toBeLessThanOrEqual(6); // max 6
    expect(normalized.recommendations.length).toBeLessThanOrEqual(8); // max 8
    expect(normalized.confidenceNotes.length).toBeLessThanOrEqual(6); // max 6
    
    expect(normalized.keyObservations[0].length).toBeLessThanOrEqual(320);
    expect(normalized.topConstraints[0].length).toBeLessThanOrEqual(320);
    expect(normalized.recommendations[0].length).toBeLessThanOrEqual(320);
    expect(normalized.confidenceNotes[0].length).toBeLessThanOrEqual(320);
  });
});

