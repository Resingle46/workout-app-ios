import type { CoachKVNamespace } from "./state";

export const GEMINI_2_5_PROVIDER_FAMILY = "gemini-2.5";
export const GEMINI_2_5_BLOCK_SCOPE = "family";
export const GEMINI_2_5_BLOCK_KEY_PREFIX = "coach:provider-family-block";
export const DEFAULT_GEMINI_EMERGENCY_FALLBACK_MODEL =
  "gemini-3.1-flash-lite-preview";
export const PACIFIC_TIME_ZONE = "America/Los_Angeles";

const GEMINI_2_5_BLOCK_TTL_BUFFER_SECONDS = 300;

export type GeminiQuotaClassificationKind =
  | "daily_quota"
  | "project_quota"
  | "transient_429"
  | "timeout"
  | "canceled"
  | "malformed_provider_response"
  | "structured_output_failure"
  | "internal_provider_error"
  | "provider_unavailable"
  | "provider_auth_failed";

export interface GeminiQuotaClassification {
  kind: GeminiQuotaClassificationKind;
  isQuotaExhausted: boolean;
  isDailyQuota: boolean;
  isTransient429: boolean;
  sourceProviderErrorStatus?: number;
  sourceProviderErrorCode?: string;
  providerMessage?: string;
}

export interface GeminiProviderFamilyBlockState {
  scope: typeof GEMINI_2_5_BLOCK_SCOPE;
  providerFamily: typeof GEMINI_2_5_PROVIDER_FAMILY;
  blockedUntil: string;
  firstSeenAt: string;
  updatedAt: string;
  reason: "daily_quota" | "project_quota";
  sourceModel: string;
  sourcePath: string;
  providerStatus?: number;
  providerCode?: string;
  rawCategory: "daily_quota" | "project_quota";
}

export interface GeminiQuotaStateEnvLike {
  COACH_STATE_KV?: CoachKVNamespace;
  GEMINI_2_5_QUOTA_BLOCK_ENABLED?: string;
  GEMINI_2_5_FAMILY_BLOCK_SCOPE?: string;
  GEMINI_EMERGENCY_FALLBACK_ENABLED?: string;
  GEMINI_EMERGENCY_FALLBACK_MODEL?: string;
}

export function isGemini2_5FamilyModel(model: string | undefined): boolean {
  const normalized = model?.trim().toLowerCase();
  return Boolean(normalized?.startsWith("gemini-2.5-"));
}

export function isGemini2_5FlashModel(model: string | undefined): boolean {
  return model?.trim().toLowerCase() === "gemini-2.5-flash";
}

export function isGemini2_5FlashLiteModel(model: string | undefined): boolean {
  return model?.trim().toLowerCase() === "gemini-2.5-flash-lite";
}

export function resolveGemini2_5BlockScope(
  env: GeminiQuotaStateEnvLike
): typeof GEMINI_2_5_BLOCK_SCOPE {
  return env.GEMINI_2_5_FAMILY_BLOCK_SCOPE?.trim().toLowerCase() === "family"
    ? "family"
    : "family";
}

export function isGemini2_5QuotaBlockEnabled(
  env: GeminiQuotaStateEnvLike
): boolean {
  return parseBooleanFlag(env.GEMINI_2_5_QUOTA_BLOCK_ENABLED, false);
}

export function isGeminiEmergencyFallbackEnabled(
  env: GeminiQuotaStateEnvLike
): boolean {
  return parseBooleanFlag(env.GEMINI_EMERGENCY_FALLBACK_ENABLED, false);
}

export function resolveGeminiEmergencyFallbackModel(
  env: GeminiQuotaStateEnvLike
): string {
  return (
    env.GEMINI_EMERGENCY_FALLBACK_MODEL?.trim() ||
    DEFAULT_GEMINI_EMERGENCY_FALLBACK_MODEL
  );
}

export function buildGemini2_5FamilyBlockKey(
  scope: typeof GEMINI_2_5_BLOCK_SCOPE = GEMINI_2_5_BLOCK_SCOPE
): string {
  return `${GEMINI_2_5_BLOCK_KEY_PREFIX}:${GEMINI_2_5_PROVIDER_FAMILY}:${scope}`;
}

export async function readGemini2_5FamilyBlockState(
  kv: CoachKVNamespace | undefined,
  options: {
    now?: Date;
    scope?: typeof GEMINI_2_5_BLOCK_SCOPE;
  } = {}
): Promise<GeminiProviderFamilyBlockState | null> {
  if (!kv) {
    return null;
  }

  const scope = options.scope ?? GEMINI_2_5_BLOCK_SCOPE;
  const key = buildGemini2_5FamilyBlockKey(scope);
  const state = await kv.get<GeminiProviderFamilyBlockState>(key, "json");
  if (!state) {
    return null;
  }

  const now = options.now ?? new Date();
  const blockedUntilMs = Date.parse(state.blockedUntil);
  if (!Number.isFinite(blockedUntilMs) || blockedUntilMs <= now.getTime()) {
    await kv.delete(key);
    return null;
  }

  return state;
}

export async function writeGemini2_5FamilyBlockState(
  kv: CoachKVNamespace | undefined,
  input: {
    now?: Date;
    scope?: typeof GEMINI_2_5_BLOCK_SCOPE;
    reason: "daily_quota" | "project_quota";
    sourceModel: string;
    sourcePath: string;
    providerStatus?: number;
    providerCode?: string;
  }
): Promise<GeminiProviderFamilyBlockState | null> {
  if (!kv) {
    return null;
  }

  const now = input.now ?? new Date();
  const scope = input.scope ?? GEMINI_2_5_BLOCK_SCOPE;
  const existing = await readGemini2_5FamilyBlockState(kv, { now, scope });
  const blockedUntil = nextPacificMidnight(now);
  const ttlSeconds =
    Math.max(
      Math.ceil((blockedUntil.getTime() - now.getTime()) / 1_000),
      1
    ) + GEMINI_2_5_BLOCK_TTL_BUFFER_SECONDS;
  const state: GeminiProviderFamilyBlockState = {
    scope,
    providerFamily: GEMINI_2_5_PROVIDER_FAMILY,
    blockedUntil: blockedUntil.toISOString(),
    firstSeenAt: existing?.firstSeenAt ?? now.toISOString(),
    updatedAt: now.toISOString(),
    reason: input.reason,
    sourceModel: input.sourceModel,
    sourcePath: input.sourcePath,
    providerStatus: input.providerStatus,
    providerCode: input.providerCode,
    rawCategory: input.reason,
  };

  await kv.put(buildGemini2_5FamilyBlockKey(scope), JSON.stringify(state), {
    expirationTtl: ttlSeconds,
  });

  return state;
}

export function classifyGeminiHttpError(
  status: number,
  payload: unknown
): GeminiQuotaClassification {
  const errorPayload =
    isRecord(payload) && isRecord(payload.error) ? payload.error : undefined;
  const providerMessage = readProviderMessage(errorPayload, status);
  const providerStatus = readProviderStatus(errorPayload);
  const normalizedMessage = providerMessage.toLowerCase();
  const normalizedStatus = providerStatus?.toLowerCase();

  if (status === 401 || status === 403) {
    return {
      kind: "provider_auth_failed",
      isQuotaExhausted: false,
      isDailyQuota: false,
      isTransient429: false,
      sourceProviderErrorStatus: status,
      sourceProviderErrorCode: providerStatus,
      providerMessage,
    };
  }

  if (status === 429) {
    const hasQuotaSignal =
      normalizedStatus === "resource_exhausted" ||
      GEMINI_QUOTA_PATTERNS.some((pattern) => pattern.test(normalizedMessage));
    const isDailyQuota =
      GEMINI_DAILY_QUOTA_PATTERNS.some((pattern) =>
        pattern.test(normalizedMessage)
      );
    if (hasQuotaSignal) {
      return {
        kind: isDailyQuota ? "daily_quota" : "project_quota",
        isQuotaExhausted: true,
        isDailyQuota,
        isTransient429: false,
        sourceProviderErrorStatus: status,
        sourceProviderErrorCode: providerStatus,
        providerMessage,
      };
    }

    return {
      kind: "transient_429",
      isQuotaExhausted: false,
      isDailyQuota: false,
      isTransient429: true,
      sourceProviderErrorStatus: status,
      sourceProviderErrorCode: providerStatus,
      providerMessage,
    };
  }

  if (status >= 500) {
    return {
      kind: "provider_unavailable",
      isQuotaExhausted: false,
      isDailyQuota: false,
      isTransient429: false,
      sourceProviderErrorStatus: status,
      sourceProviderErrorCode: providerStatus,
      providerMessage,
    };
  }

  return {
    kind: "internal_provider_error",
    isQuotaExhausted: false,
    isDailyQuota: false,
    isTransient429: false,
    sourceProviderErrorStatus: status,
    sourceProviderErrorCode: providerStatus,
    providerMessage,
  };
}

export function classifyGeminiServiceFailure(input: {
  code: string;
  details?: Record<string, unknown>;
}): GeminiQuotaClassification {
  const kind = readNonEmptyString(input.details?.quotaClassificationKind);
  if (kind && isGeminiQuotaClassificationKind(kind)) {
    return {
      kind,
      isQuotaExhausted:
        kind === "daily_quota" || kind === "project_quota",
      isDailyQuota: kind === "daily_quota",
      isTransient429: kind === "transient_429",
      sourceProviderErrorStatus: readFiniteNumber(
        input.details?.sourceProviderErrorStatus
      ),
      sourceProviderErrorCode: readNonEmptyString(
        input.details?.sourceProviderErrorCode
      ),
      providerMessage: readNonEmptyString(input.details?.providerMessage),
    };
  }

  switch (input.code) {
    case "gemini_daily_quota_exhausted":
      return {
        kind: "daily_quota",
        isQuotaExhausted: true,
        isDailyQuota: true,
        isTransient429: false,
        sourceProviderErrorStatus: readFiniteNumber(
          input.details?.sourceProviderErrorStatus
        ),
        sourceProviderErrorCode: readNonEmptyString(
          input.details?.sourceProviderErrorCode
        ),
        providerMessage: readNonEmptyString(input.details?.providerMessage),
      };
    case "provider_quota_exhausted":
      return {
        kind: "project_quota",
        isQuotaExhausted: true,
        isDailyQuota: false,
        isTransient429: false,
        sourceProviderErrorStatus: readFiniteNumber(
          input.details?.sourceProviderErrorStatus
        ),
        sourceProviderErrorCode: readNonEmptyString(
          input.details?.sourceProviderErrorCode
        ),
        providerMessage: readNonEmptyString(input.details?.providerMessage),
      };
    case "provider_family_blocked":
      return {
        kind:
          readNonEmptyString(input.details?.quotaClassificationKind) ===
          "project_quota"
            ? "project_quota"
            : "daily_quota",
        isQuotaExhausted: true,
        isDailyQuota:
          readNonEmptyString(input.details?.quotaClassificationKind) !==
          "project_quota",
        isTransient429: false,
        sourceProviderErrorStatus: readFiniteNumber(
          input.details?.sourceProviderErrorStatus
        ),
        sourceProviderErrorCode: readNonEmptyString(
          input.details?.sourceProviderErrorCode
        ),
        providerMessage: readNonEmptyString(input.details?.providerMessage),
      };
    case "upstream_timeout":
      return {
        kind: "timeout",
        isQuotaExhausted: false,
        isDailyQuota: false,
        isTransient429: false,
      };
    case "upstream_invalid_json":
    case "upstream_empty_output":
      return {
        kind: "malformed_provider_response",
        isQuotaExhausted: false,
        isDailyQuota: false,
        isTransient429: false,
      };
    case "upstream_invalid_output":
      return {
        kind: "structured_output_failure",
        isQuotaExhausted: false,
        isDailyQuota: false,
        isTransient429: false,
      };
    case "provider_unavailable":
      return {
        kind: "provider_unavailable",
        isQuotaExhausted: false,
        isDailyQuota: false,
        isTransient429: false,
      };
    case "provider_auth_failed":
      return {
        kind: "provider_auth_failed",
        isQuotaExhausted: false,
        isDailyQuota: false,
        isTransient429: false,
      };
    default:
      return {
        kind: "internal_provider_error",
        isQuotaExhausted: false,
        isDailyQuota: false,
        isTransient429: false,
      };
  }
}

export function nextPacificMidnight(now: Date): Date {
  const pacificDate = pacificDateParts(now);
  const nextDay = new Date(
    Date.UTC(pacificDate.year, pacificDate.month - 1, pacificDate.day)
  );
  nextDay.setUTCDate(nextDay.getUTCDate() + 1);
  return zonedDateTimeToUtc(
    nextDay.getUTCFullYear(),
    nextDay.getUTCMonth() + 1,
    nextDay.getUTCDate(),
    0,
    0,
    0,
    PACIFIC_TIME_ZONE
  );
}

function pacificDateParts(now: Date): {
  year: number;
  month: number;
  day: number;
} {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: PACIFIC_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);

  return {
    year: readRequiredPart(parts, "year"),
    month: readRequiredPart(parts, "month"),
    day: readRequiredPart(parts, "day"),
  };
}

function zonedDateTimeToUtc(
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
  second: number,
  timeZone: string
): Date {
  let utcMs = Date.UTC(year, month - 1, day, hour, minute, second);

  for (let iteration = 0; iteration < 4; iteration += 1) {
    const offsetMs = timeZoneOffsetMs(new Date(utcMs), timeZone);
    const adjustedUtcMs =
      Date.UTC(year, month - 1, day, hour, minute, second) - offsetMs;
    if (adjustedUtcMs === utcMs) {
      break;
    }
    utcMs = adjustedUtcMs;
  }

  return new Date(utcMs);
}

function timeZoneOffsetMs(date: Date, timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);

  const year = readRequiredPart(parts, "year");
  const month = readRequiredPart(parts, "month");
  const day = readRequiredPart(parts, "day");
  const hour = readRequiredPart(parts, "hour");
  const minute = readRequiredPart(parts, "minute");
  const second = readRequiredPart(parts, "second");

  return (
    Date.UTC(year, month - 1, day, hour, minute, second) - date.getTime()
  );
}

function readRequiredPart(
  parts: Intl.DateTimeFormatPart[],
  type: Intl.DateTimeFormatPartTypes
): number {
  const value = parts.find((part) => part.type === type)?.value;
  const parsed = Number.parseInt(value ?? "", 10);
  if (!Number.isFinite(parsed)) {
    throw new Error(`Failed to read ${type} from Intl.DateTimeFormat parts.`);
  }
  return parsed;
}

function parseBooleanFlag(value: string | undefined, fallback: boolean): boolean {
  if (!value) {
    return fallback;
  }

  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}

function readProviderMessage(
  errorPayload: Record<string, unknown> | undefined,
  status: number
): string {
  const message = readNonEmptyString(errorPayload?.message);
  return message ?? `Gemini request failed with status ${status}`;
}

function readProviderStatus(
  errorPayload: Record<string, unknown> | undefined
): string | undefined {
  return (
    readNonEmptyString(errorPayload?.status) ??
    readNonEmptyString(errorPayload?.code)
  );
}

function readNonEmptyString(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function readFiniteNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isGeminiQuotaClassificationKind(
  value: string
): value is GeminiQuotaClassificationKind {
  return (
    value === "daily_quota" ||
    value === "project_quota" ||
    value === "transient_429" ||
    value === "timeout" ||
    value === "canceled" ||
    value === "malformed_provider_response" ||
    value === "structured_output_failure" ||
    value === "internal_provider_error" ||
    value === "provider_unavailable" ||
    value === "provider_auth_failed"
  );
}

const GEMINI_QUOTA_PATTERNS = [
  /\bquota exceeded\b/i,
  /\bdaily limit\b/i,
  /\bdaily quota\b/i,
  /\brequests?\s+per\s+day\b/i,
  /\brpd\b/i,
  /\bexhausted quota\b/i,
  /\bquota exhausted\b/i,
  /\bresource exhausted\b/i,
  /\bresource_exhausted\b/i,
];

const GEMINI_DAILY_QUOTA_PATTERNS = [
  /\bdaily limit\b/i,
  /\bdaily quota\b/i,
  /\brequests?\s+per\s+day\b/i,
  /\brpd\b/i,
];
