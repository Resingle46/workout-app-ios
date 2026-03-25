import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app";
import {
  CoachInferenceServiceError,
  DEFAULT_AI_MODEL,
  WorkersAICoachService,
  type CoachInferenceService,
  type Env,
} from "../src/openai";
import type {
  CoachChatRequest,
  CoachChatResponse,
  CoachProfileInsightsRequest,
  CoachProfileInsightsResponse,
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
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
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

  it("rejects invalid auth token", async () => {
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
    });

    const response = await app.fetch(
      new Request("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        headers: {
          authorization: "Bearer wrong-token",
          "content-type": "application/json",
        },
        body: JSON.stringify(makeProfileInsightsRequestFixture()),
      }),
      makeEnv()
    );

    expect(response.status).toBe(401);
  });

  it("accepts valid profile insights request with current app JSON shape", async () => {
    const service = stubInferenceService({
      profileInsights: {
        summary: "Volume is trending up.",
        recommendations: ["Keep upper day intensity high."],
        suggestedChanges: [],
      },
    });
    const app = createApp({
      createInferenceService: () => service,
    });

    const response = await app.fetch(
      new Request("https://coach.example.workers.dev/v1/coach/profile-insights", {
        method: "POST",
        headers: {
          authorization: "Bearer internal-token",
          "content-type": "application/json",
        },
        body: JSON.stringify(makeProfileInsightsRequestFixture()),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      summary: "Volume is trending up.",
      recommendations: ["Keep upper day intensity high."],
      suggestedChanges: [],
    });
  });

  it("accepts valid chat request with replayed conversation messages", async () => {
    const service = stubInferenceService({
      chat: {
        answerMarkdown: "Increase load conservatively next week.",
        responseID: "coach-turn_123",
        followUps: ["Do you want a set-by-set progression?"],
        suggestedChanges: [],
      },
    });
    const app = createApp({
      createInferenceService: () => service,
    });

    const response = await app.fetch(
      new Request("https://coach.example.workers.dev/v1/coach/chat", {
        method: "POST",
        headers: {
          authorization: "Bearer internal-token",
          "content-type": "application/json",
        },
        body: JSON.stringify(makeChatRequestFixture()),
      }),
      makeEnv()
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      answerMarkdown: "Increase load conservatively next week.",
      responseID: "coach-turn_123",
      followUps: ["Do you want a set-by-set progression?"],
      suggestedChanges: [],
    });
  });

  it("maps invalid request bodies to 400", async () => {
    const app = createApp({
      createInferenceService: () => stubInferenceService(),
    });

    const response = await app.fetch(
      new Request("https://coach.example.workers.dev/v1/coach/chat", {
        method: "POST",
        headers: {
          authorization: "Bearer internal-token",
          "content-type": "application/json",
        },
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

  it("maps upstream failures to stable 5xx errors", async () => {
    const app = createApp({
      createInferenceService: () =>
        stubInferenceService({
          chatError: new CoachInferenceServiceError(
            502,
            "upstream_request_failed",
            "Workers AI request failed"
          ),
        }),
    });

    const response = await app.fetch(
      new Request("https://coach.example.workers.dev/v1/coach/chat", {
        method: "POST",
        headers: {
          authorization: "Bearer internal-token",
          "content-type": "application/json",
        },
        body: JSON.stringify(makeChatRequestFixture()),
      }),
      makeEnv()
    );

    expect(response.status).toBe(502);
    await expect(response.json()).resolves.toMatchObject({
      error: {
        code: "upstream_request_failed",
        message: "Coach upstream request failed.",
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
        suggestedChanges: [],
      },
      usage: { total_tokens: 321 },
    });

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const result = await service.generateChat(makeChatRequestFixture());

    expect(aiRun).toHaveBeenCalledTimes(1);
    const [model, payload] = aiRun.mock.calls[0] ?? [];
    expect(model).toBe(DEFAULT_AI_MODEL);
    expect(payload).toMatchObject({
      max_tokens: 900,
      temperature: 0.2,
      guided_json: expect.any(Object),
    });
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
    expect(result.data.responseID).toMatch(/^coach-turn_/);
  });

  it("drops invalid suggestedChanges instead of failing the whole chat response", async () => {
    const aiRun = vi.fn().mockResolvedValue({
      response: {
        answerMarkdown: "Keep one rep in reserve on compounds this week.",
        followUps: ["Want that translated into set targets?"],
        suggestedChanges: [
          {
            id: "bad-change",
            type: "setWeeklyWorkoutTarget",
            title: "Broken draft",
            summary: "Missing weekly target value",
          },
        ],
      },
    });

    const service = new WorkersAICoachService(makeEnv({ AI: { run: aiRun } }));
    const result = await service.generateChat(makeChatRequestFixture());

    expect(result.data.suggestedChanges).toEqual([]);
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
    expect(result.data.answerMarkdown).toBe(
      "Keep load the same next week and add one rep to the final set."
    );
    expect(result.data.followUps).toEqual([]);
    expect(result.data.suggestedChanges).toEqual([]);
    expect(result.data.responseID).toMatch(/^coach-turn_/);
  });

  it("rejects invalid structured profile output", async () => {
    const service = new WorkersAICoachService(
      makeEnv({
        AI: {
          run: vi.fn().mockResolvedValue({
            response: {
              summary: "",
              recommendations: [],
              suggestedChanges: [],
            },
          }),
        },
      })
    );

    await expect(
      service.generateProfileInsights(makeProfileInsightsRequestFixture())
    ).rejects.toMatchObject({
      code: "upstream_invalid_output",
      status: 502,
    });
  });

  it("maps timeout-like upstream errors to 504", async () => {
    const service = new WorkersAICoachService(
      makeEnv({
        AI: {
          run: vi.fn().mockRejectedValue(new Error("Request timed out")),
        },
      })
    );

    await expect(
      service.generateProfileInsights(makeProfileInsightsRequestFixture())
    ).rejects.toMatchObject({
      code: "upstream_timeout",
      status: 504,
    });
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
          suggestedChanges: [],
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
          suggestedChanges: [],
        },
        responseId: "coach-turn_1",
        model: DEFAULT_AI_MODEL,
      };
    },
  };
}

function makeEnv(overrides: Partial<Env> = {}): Env {
  return {
    AI: {
      run: vi.fn(),
    },
    COACH_INTERNAL_TOKEN: "internal-token",
    AI_MODEL: DEFAULT_AI_MODEL,
    COACH_PROMPT_VERSION: "test.v1",
    ...overrides,
  };
}

function makeProfileInsightsRequestFixture(): CoachProfileInsightsRequest {
  return {
    locale: "en",
    capabilityScope: "draft_changes",
    context: {
      localeIdentifier: "en",
      historyMode: "summary_recent_history",
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
      preferredProgram: {
        id: "11111111-1111-4111-8111-111111111111",
        title: "Upper Lower",
        workoutCount: 4,
        workouts: [
          {
            id: "22222222-2222-4222-8222-222222222222",
            title: "Upper A",
            focus: "Chest and back",
            exerciseCount: 2,
            exercises: [
              {
                templateExerciseID: "33333333-3333-4333-8333-333333333333",
                exerciseID: "44444444-4444-4444-8444-444444444444",
                exerciseName: "Barbell Bench Press",
                setsCount: 4,
                reps: 5,
                suggestedWeight: 90,
                groupKind: "regular",
              },
              {
                templateExerciseID: "55555555-5555-4555-8555-555555555555",
                exerciseID: "66666666-6666-4666-8666-666666666666",
                exerciseName: "Barbell Row",
                setsCount: 4,
                reps: 6,
                suggestedWeight: 80,
                groupKind: "regular",
              },
            ],
          },
        ],
      },
      activeWorkout: {
        workoutTemplateID: "22222222-2222-4222-8222-222222222222",
        title: "Upper A",
        startedAt: "2026-03-25T12:00:00.000Z",
        exerciseCount: 2,
        completedSetsCount: 3,
        totalSetsCount: 8,
      },
      analytics: {
        progress30Days: {
          totalFinishedWorkouts: 14,
          recentExercisesCount: 28,
          recentVolume: 24680,
          averageDurationSeconds: 4100,
          lastWorkoutDate: "2026-03-24T18:30:00.000Z",
        },
        goal: {
          primaryGoal: "strength",
          currentWeight: 86,
          targetBodyWeight: 88,
          weeklyWorkoutTarget: 4,
          safeWeeklyChangeLowerBound: 0.15,
          safeWeeklyChangeUpperBound: 0.3,
          etaWeeksLowerBound: 6,
          etaWeeksUpperBound: 10,
          usesCurrentWeightOnly: false,
        },
        training: {
          currentWeeklyTarget: 4,
          recommendedWeeklyTargetLowerBound: 3,
          recommendedWeeklyTargetUpperBound: 5,
          mainRepLowerBound: 3,
          mainRepUpperBound: 6,
          accessoryRepLowerBound: 6,
          accessoryRepUpperBound: 10,
          weeklySetsLowerBound: 10,
          weeklySetsUpperBound: 14,
          split: "upper_lower",
          splitWorkoutDays: 4,
          splitProgramTitle: "Upper Lower",
          isGenericFallback: false,
        },
        compatibility: {
          isAligned: true,
          issues: [],
        },
        consistency: {
          workoutsThisWeek: 3,
          weeklyTarget: 4,
          streakWeeks: 4,
          mostFrequentWeekday: 2,
          recentWeeklyActivity: [
            {
              weekStart: "2026-03-17T00:00:00.000Z",
              workoutsCount: 4,
              meetsTarget: true,
            },
          ],
        },
        recentPersonalRecords: [
          {
            exerciseID: "44444444-4444-4444-8444-444444444444",
            exerciseName: "Barbell Bench Press",
            achievedAt: "2026-03-20T18:00:00.000Z",
            weight: 102.5,
            previousWeight: 100,
            delta: 2.5,
          },
        ],
        relativeStrength: [
          {
            lift: "bench_press",
            bestLoad: 102.5,
            relativeToBodyWeight: 1.19,
          },
        ],
      },
      recentFinishedSessions: [
        {
          id: "77777777-7777-4777-8777-777777777777",
          workoutTemplateID: "22222222-2222-4222-8222-222222222222",
          title: "Upper A",
          startedAt: "2026-03-24T17:00:00.000Z",
          endedAt: "2026-03-24T18:15:00.000Z",
          durationSeconds: 4500,
          completedSetsCount: 8,
          totalVolume: 6240,
          exercises: [
            {
              templateExerciseID: "33333333-3333-4333-8333-333333333333",
              exerciseID: "44444444-4444-4444-8444-444444444444",
              exerciseName: "Barbell Bench Press",
              groupKind: "regular",
              completedSetsCount: 4,
              bestWeight: 100,
              totalVolume: 2000,
              averageReps: 5,
              performedSets: [
                {
                  reps: 5,
                  weight: 100,
                  completedAt: "2026-03-24T17:10:00.000Z",
                },
              ],
            },
          ],
        },
      ],
    },
  };
}

function makeChatRequestFixture(): CoachChatRequest {
  return {
    ...makeProfileInsightsRequestFixture(),
    question: "How should I progress next week?",
    previousResponseID: "resp_prev_001",
    conversationMessages: [
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
