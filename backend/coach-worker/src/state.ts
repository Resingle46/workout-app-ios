import type {
  CoachConversationTurn,
  CoachProfileInsightsResponse,
  CoachSnapshotSyncRequest,
  CompactCoachSnapshot,
} from "./schemas";

const SNAPSHOT_TTL_SECONDS = 30 * 24 * 60 * 60;
const CHAT_MEMORY_TTL_SECONDS = 7 * 24 * 60 * 60;
const INSIGHTS_CACHE_TTL_SECONDS = 6 * 60 * 60;
const CHAT_MEMORY_MAX_TURNS = 6;
const CHAT_MEMORY_MAX_CONTENT_LENGTH = 500;

export interface CoachKVNamespace {
  get(key: string, type: "text"): Promise<string | null>;
  get<T = unknown>(key: string, type: "json"): Promise<T | null>;
  put(
    key: string,
    value: string,
    options?: {
      expirationTtl?: number;
    }
  ): Promise<void>;
  delete(key: string): Promise<void>;
  list(options?: {
    prefix?: string;
    cursor?: string;
    limit?: number;
  }): Promise<{
    keys: Array<{ name: string }>;
    list_complete: boolean;
    cursor?: string;
  }>;
}

export interface StoredCoachSnapshot {
  hash: string;
  updatedAt: string;
  locale: string;
  snapshot: CompactCoachSnapshot;
}

export interface StoredChatMemory {
  updatedAt: string;
  recentTurns: CoachConversationTurn[];
}

export interface SnapshotResolution {
  snapshot?: CompactCoachSnapshot;
  acceptedHash?: string;
  storedAt?: string;
  snapshotHit: boolean;
  snapshotStored: boolean;
  snapshotBytes: number;
}

export interface SnapshotEnvelopeInput {
  installID: string;
  snapshotHash: string;
  snapshot?: CompactCoachSnapshot;
  snapshotUpdatedAt?: string;
}

export class CoachStateRepository {
  constructor(
    private readonly kv: CoachKVNamespace,
    private readonly promptVersion: string,
    private readonly model: string,
    private readonly now: () => Date = () => new Date()
  ) {}

  async getSnapshot(installID: string): Promise<StoredCoachSnapshot | null> {
    return this.kv.get<StoredCoachSnapshot>(snapshotKey(installID), "json");
  }

  async resolveSnapshot(
    request: SnapshotEnvelopeInput
  ): Promise<SnapshotResolution> {
    const storedSnapshot = await this.getSnapshot(request.installID);
    if (storedSnapshot?.hash === request.snapshotHash) {
      return {
        snapshot: storedSnapshot.snapshot,
        acceptedHash: storedSnapshot.hash,
        storedAt: storedSnapshot.updatedAt,
        snapshotHit: true,
        snapshotStored: false,
        snapshotBytes: jsonByteLength(storedSnapshot.snapshot),
      };
    }

    if (!request.snapshot) {
      return {
        snapshotHit: false,
        snapshotStored: false,
        snapshotBytes: 0,
      };
    }

    const acceptedHash = await hashSnapshot(request.snapshot);
    const storedAt = request.snapshotUpdatedAt ?? this.now().toISOString();
    const envelope: StoredCoachSnapshot = {
      hash: acceptedHash,
      updatedAt: storedAt,
      locale: request.snapshot.localeIdentifier,
      snapshot: request.snapshot,
    };

    await this.kv.put(
      snapshotKey(request.installID),
      JSON.stringify(envelope),
      { expirationTtl: SNAPSHOT_TTL_SECONDS }
    );

    return {
      snapshot: request.snapshot,
      acceptedHash,
      storedAt,
      snapshotHit: false,
      snapshotStored: true,
      snapshotBytes: jsonByteLength(request.snapshot),
    };
  }

  async storeSnapshot(
    request: CoachSnapshotSyncRequest
  ): Promise<{ acceptedHash: string; storedAt: string }> {
    const resolution = await this.resolveSnapshot(request);
    return {
      acceptedHash: resolution.acceptedHash ?? request.snapshotHash,
      storedAt: resolution.storedAt ?? request.snapshotUpdatedAt,
    };
  }

  async getInsightsCache(
    installID: string,
    snapshotHash: string
  ): Promise<CoachProfileInsightsResponse | null> {
    return this.kv.get<CoachProfileInsightsResponse>(
      insightsCacheKey(installID, snapshotHash, this.promptVersion, this.model),
      "json"
    );
  }

  async storeInsightsCache(
    installID: string,
    snapshotHash: string,
    response: CoachProfileInsightsResponse
  ): Promise<void> {
    await this.kv.put(
      insightsCacheKey(installID, snapshotHash, this.promptVersion, this.model),
      JSON.stringify(response),
      { expirationTtl: INSIGHTS_CACHE_TTL_SECONDS }
    );
  }

  async getChatMemory(installID: string): Promise<StoredChatMemory | null> {
    return this.kv.get<StoredChatMemory>(chatMemoryKey(installID), "json");
  }

  async storeChatMemory(
    installID: string,
    turns: CoachConversationTurn[]
  ): Promise<StoredChatMemory> {
    const memory: StoredChatMemory = {
      updatedAt: this.now().toISOString(),
      recentTurns: normalizeChatTurns(turns),
    };

    await this.kv.put(
      chatMemoryKey(installID),
      JSON.stringify(memory),
      { expirationTtl: CHAT_MEMORY_TTL_SECONDS }
    );

    return memory;
  }

  async appendChatMemory(
    installID: string,
    baseTurns: CoachConversationTurn[],
    question: string,
    answerMarkdown: string
  ): Promise<StoredChatMemory> {
    return this.storeChatMemory(installID, [
      ...baseTurns,
      { role: "user", content: question },
      { role: "assistant", content: answerMarkdown },
    ]);
  }

  async deleteInstallState(installID: string): Promise<void> {
    await this.kv.delete(snapshotKey(installID));
    await this.kv.delete(chatMemoryKey(installID));

    let cursor: string | undefined;
    do {
      const page = await this.kv.list({
        prefix: insightsCachePrefix(installID),
        cursor,
        limit: 100,
      });

      await Promise.all(page.keys.map((key) => this.kv.delete(key.name)));
      cursor = page.list_complete ? undefined : page.cursor;
    } while (cursor);
  }
}

export function normalizeChatTurns(
  turns: CoachConversationTurn[]
): CoachConversationTurn[] {
  return turns
    .map((turn) => ({
      role: turn.role,
      content: turn.content.trim().slice(0, CHAT_MEMORY_MAX_CONTENT_LENGTH),
    }))
    .filter((turn) => turn.content.length > 0)
    .slice(-CHAT_MEMORY_MAX_TURNS);
}

export async function hashSnapshot(
  snapshot: CompactCoachSnapshot
): Promise<string> {
  const encoder = new TextEncoder();
  const digest = await crypto.subtle.digest(
    "SHA-256",
    encoder.encode(stableJSONStringify(snapshot))
  );
  return Array.from(new Uint8Array(digest))
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
}

export function jsonByteLength(value: unknown): number {
  return new TextEncoder().encode(JSON.stringify(value)).length;
}

function snapshotKey(installID: string): string {
  return `snapshot:${installID}`;
}

function chatMemoryKey(installID: string): string {
  return `chat-memory:${installID}`;
}

function insightsCachePrefix(installID: string): string {
  return `insights-cache:${installID}:`;
}

function insightsCacheKey(
  installID: string,
  snapshotHash: string,
  promptVersion: string,
  model: string
): string {
  return `${insightsCachePrefix(installID)}${snapshotHash}:${promptVersion}:${model}`;
}

function stableJSONStringify(value: unknown): string {
  return JSON.stringify(sortJSONValue(value));
}

function sortJSONValue(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sortJSONValue);
  }

  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, nested]) => [key, sortJSONValue(nested)])
    );
  }

  return value;
}
