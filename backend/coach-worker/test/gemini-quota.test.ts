import { describe, expect, it } from "vitest";
import type { CoachKVNamespace } from "../src/state";
import {
  buildGemini2_5FamilyBlockKey,
  classifyGeminiHttpError,
  nextPacificMidnight,
  readGemini2_5FamilyBlockState,
  writeGemini2_5FamilyBlockState,
} from "../src/gemini-quota";

describe("gemini quota helpers", () => {
  it("classifies Gemini quota and transient 429 responses separately", () => {
    expect(
      classifyGeminiHttpError(429, {
        error: {
          message: "Daily quota exceeded. Requests per day exhausted.",
          status: "RESOURCE_EXHAUSTED",
        },
      })
    ).toMatchObject({
      kind: "daily_quota",
      isQuotaExhausted: true,
      isDailyQuota: true,
      isTransient429: false,
    });

    expect(
      classifyGeminiHttpError(429, {
        error: {
          message: "Project quota exceeded.",
          status: "RESOURCE_EXHAUSTED",
        },
      })
    ).toMatchObject({
      kind: "project_quota",
      isQuotaExhausted: true,
      isDailyQuota: false,
      isTransient429: false,
    });

    expect(
      classifyGeminiHttpError(429, {
        error: {
          message: "Too many requests right now.",
          status: "UNAVAILABLE",
        },
      })
    ).toMatchObject({
      kind: "transient_429",
      isQuotaExhausted: false,
      isTransient429: true,
    });
  });

  it("computes the next Pacific midnight across DST boundaries", () => {
    expect(
      nextPacificMidnight(new Date("2026-03-08T09:30:00.000Z")).toISOString()
    ).toBe("2026-03-09T07:00:00.000Z");

    expect(
      nextPacificMidnight(new Date("2026-11-01T08:30:00.000Z")).toISOString()
    ).toBe("2026-11-02T08:00:00.000Z");
  });

  it("persists Gemini 2.5 family block state under the explicit KV key", async () => {
    const kv = makeMemoryKV();
    const now = new Date("2026-03-28T18:15:00.000Z");

    const written = await writeGemini2_5FamilyBlockState(kv, {
      now,
      reason: "daily_quota",
      sourceModel: "gemini-2.5-flash-lite",
      sourcePath: "profile_insights",
      providerStatus: 429,
      providerCode: "RESOURCE_EXHAUSTED",
    });

    expect(buildGemini2_5FamilyBlockKey()).toBe(
      "coach:provider-family-block:gemini-2.5:family"
    );
    expect(written).toMatchObject({
      providerFamily: "gemini-2.5",
      scope: "family",
      rawCategory: "daily_quota",
      sourceModel: "gemini-2.5-flash-lite",
      sourcePath: "profile_insights",
    });
    await expect(
      readGemini2_5FamilyBlockState(kv, { now })
    ).resolves.toMatchObject({
      providerFamily: "gemini-2.5",
      rawCategory: "daily_quota",
    });
  });
});

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
