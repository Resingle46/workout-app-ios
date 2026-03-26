import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app";
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
import { InMemoryCoachStateRepository } from "../src/state";
import type {
  AppSnapshotPayload,
  BackupUploadRequest,
  CoachChatRequest,
  CoachChatResponse,
  CoachProfileInsightsRequest,
  CoachProfileInsightsResponse,
  CompactCoachSnapshot,
} from "../src/schemas";

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
            },
            model: DEFAULT_AI_MODEL,
          };
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
            },
            model: DEFAULT_AI_MODEL,
          };
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
            },
            model: DEFAULT_AI_MODEL,
          };
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
    await repository.storeInsightsCache(upload.installID, context.contextHash, {
      summary: "Cached fallback summary",
      recommendations: ["Cached fallback recommendation"],
      generationStatus: "fallback",
    });

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
    });
  });

  it("uses server-side context for slim chat requests", async () => {
    const repository = new InMemoryCoachStateRepository("test.v1", DEFAULT_AI_MODEL);
    let capturedRequest: CoachChatRequest | undefined;
    const app = createApp({
      createInferenceService: () => ({
        async generateProfileInsights() {
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

describe("WorkersAICoachService", () => {
  it("replays recent conversation turns and ignores previousResponseID", async () => {
    const aiRun = vi.fn().mockResolvedValue({
      response: {
        answerMarkdown: "Use +2.5kg if RPE stayed below 8.",
        followUps: ["Want a double progression version?"],
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
});

function stubInferenceService(overrides?: {
  profileInsights?: CoachProfileInsightsResponse;
  chat?: CoachChatResponse;
  chatError?: Error;
}): CoachInferenceService {
  return {
    async generateProfileInsights() {
      return {
        data: overrides?.profileInsights ?? {
          summary: "Summary",
          recommendations: ["Recommendation"],
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
    COACH_INTERNAL_TOKEN: "internal-token",
    AI_MODEL: DEFAULT_AI_MODEL,
    COACH_PROMPT_VERSION: "test.v1",
    ...overrides,
  };
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
  };
}

function makeChatRequestFixture(): CoachChatRequest {
  return {
    ...makeProfileInsightsRequestFixture(),
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
