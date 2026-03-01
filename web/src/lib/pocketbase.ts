import PocketBase from "pocketbase";
import type { ClawChatMessage, PostHistoryItem, StoredDraft } from "./types";

function resolveGatewayEndpoint(path: string, gatewayBaseUrl?: string): string {
  if (!gatewayBaseUrl || !gatewayBaseUrl.trim()) {
    return path;
  }
  const base = gatewayBaseUrl.trim().replace(/\/+$/, "");
  const suffix = path.startsWith("/") ? path : `/${path}`;
  return `${base}${suffix}`;
}

function defaultPocketBaseUrl() {
  if (typeof window === "undefined") {
    return "http://127.0.0.1:8090";
  }
  const protocol = window.location.protocol === "https:" ? "https:" : "http:";
  const host = window.location.hostname || "127.0.0.1";
  return `${protocol}//${host}:8090`;
}

export function createPocketBaseClient(baseUrl: string) {
  return new PocketBase(baseUrl || defaultPocketBaseUrl());
}

export function pocketBaseAuthLabel(pb: PocketBase): string {
  const model = pb.authStore.model as Record<string, unknown> | null;
  if (!model) {
    return "";
  }
  const email = typeof model.email === "string" ? model.email : "";
  const username = typeof model.username === "string" ? model.username : "";
  const id = typeof model.id === "string" ? model.id : "";
  return email || username || id;
}

export async function loginPocketBase(
  pb: PocketBase,
  identity: string,
  password: string
) {
  const user = identity.trim();
  const pass = password.trim();
  if (!user || !pass) {
    throw new Error("Identity and password are required");
  }

  let lastError: unknown = null;
  const attempts = [
    () => pb.collection("_superusers").authWithPassword(user, pass),
    () => pb.collection("users").authWithPassword(user, pass)
  ];
  for (const attempt of attempts) {
    try {
      return await attempt();
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError instanceof Error
    ? lastError
    : new Error("PocketBase login failed");
}

export function logoutPocketBase(pb: PocketBase) {
  pb.authStore.clear();
}

function normalizePocketBaseUsername(raw: string) {
  const normalized = raw
    .toLowerCase()
    .replace(/[^a-z0-9._-]/g, "_")
    .replace(/_+/g, "_")
    .replace(/^[_\-.]+|[_\-.]+$/g, "");
  const clipped = normalized.slice(0, 40);
  if (clipped.length >= 3) {
    return clipped;
  }
  return `user_${Date.now().toString(36)}`;
}

async function authUsersWithAnyIdentity(
  pb: PocketBase,
  identities: string[],
  password: string
) {
  let lastError: unknown = null;
  for (const identity of identities) {
    const candidate = identity.trim();
    if (!candidate) {
      continue;
    }
    try {
      await pb.collection("users").authWithPassword(candidate, password);
      return candidate;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError instanceof Error
    ? lastError
    : new Error("PocketBase users auth failed");
}

export async function ensurePocketBaseUserFromBluesky(
  pb: PocketBase,
  identity: string,
  password: string,
  sessionHandle: string
) {
  const rawIdentity = identity.trim();
  const rawPassword = password.trim();
  if (!rawIdentity || !rawPassword) {
    throw new Error("Bluesky identity and app password are required");
  }

  const basis = sessionHandle.trim() || rawIdentity;
  const username = normalizePocketBaseUsername(basis);
  const email = rawIdentity.includes("@")
    ? rawIdentity.toLowerCase()
    : `${username}@slowclaw.local`;
  const identities = Array.from(
    new Set(
      [rawIdentity, sessionHandle.trim(), email, username].filter(
        (value): value is string => !!value && value.trim().length > 0
      )
    )
  );

  try {
    const usedIdentity = await authUsersWithAnyIdentity(pb, identities, rawPassword);
    return { created: false, identity: usedIdentity };
  } catch {
    // create below
  }

  try {
    await pb.collection("users").create({
      username,
      email,
      emailVisibility: true,
      password: rawPassword,
      passwordConfirm: rawPassword,
      name: sessionHandle.trim() || username
    });
  } catch {
    // If user already exists/raced, auth retry below is authoritative.
  }

  const usedIdentity = await authUsersWithAnyIdentity(pb, identities, rawPassword);
  return { created: true, identity: usedIdentity };
}

export async function saveDraftToPocketBase(pb: PocketBase, draft: StoredDraft) {
  const payload = {
    text: draft.text,
    videoName: draft.videoName || "",
    createdAtClient: draft.created,
    updatedAtClient: new Date().toISOString()
  };

  if (draft.id) {
    return pb.collection("drafts").update(draft.id, payload);
  }

  return pb.collection("drafts").create(payload);
}

export async function listDraftsFromPocketBase(pb: PocketBase) {
  return pb.collection("drafts").getList(1, 20, {
    sort: "-created"
  });
}

export async function savePostHistoryToPocketBase(
  pb: PocketBase,
  item: PostHistoryItem
) {
  return pb.collection("post_history").create({
    provider: item.provider,
    text: item.text,
    videoName: item.videoName || "",
    uri: item.uri || "",
    cid: item.cid || "",
    status: item.status,
    error: item.error || "",
    createdAtClient: item.created
  });
}

export async function listPostHistoryFromPocketBase(pb: PocketBase): Promise<PostHistoryItem[]> {
  const result = await pb.collection("post_history").getList(1, 50, {
    sort: "-created"
  });
  return result.items.map((item: any) => ({
    id: String(item.id || ""),
    provider: "bluesky",
    text: String(item.text || ""),
    videoName: item.videoName ? String(item.videoName) : undefined,
    uri: item.uri ? String(item.uri) : undefined,
    cid: item.cid ? String(item.cid) : undefined,
    created: String(item.createdAtClient || item.created || ""),
    status: item.status === "success" ? "success" : "error",
    error: item.error ? String(item.error) : undefined
  }));
}

export async function listClawChatMessagesFromPocketBase(
  pb: PocketBase,
  threadId: string
): Promise<ClawChatMessage[]> {
  // PocketBase query parsing varies across versions and can return a generic 400
  // for otherwise-valid filter/sort expressions. Fetch a bounded page and filter locally.
  const result = await pb.collection("chat_messages").getList(1, 200);
  const records = result.items
    .filter((item) => String(item.threadId || "") === threadId)
    .sort((a, b) => {
      const aTs = String(a.createdAtClient || a.created || "");
      const bTs = String(b.createdAtClient || b.created || "");
      return aTs.localeCompare(bTs);
    });

  return records.map((item) => ({
    id: item.id,
    threadId: String(item.threadId || threadId),
    role:
      item.role === "assistant" || item.role === "system" ? item.role : "user",
    content: String(item.content || ""),
    status: String(item.status || "done"),
    error: item.error ? String(item.error) : undefined,
    source: item.source ? String(item.source) : undefined,
    replyToId: item.replyToId ? String(item.replyToId) : undefined,
    created: String(item.createdAtClient || item.created || ""),
    updated: String(item.updated || "")
  }));
}

export async function createClawChatUserMessage(
  pb: PocketBase,
  threadId: string,
  content: string
) {
  return pb.collection("chat_messages").create({
    threadId,
    role: "user",
    content,
    status: "pending",
    source: "web-ui",
    createdAtClient: new Date().toISOString()
  });
}

export async function findLatestChatThreadIdFromPocketBase(
  pb: PocketBase
): Promise<string | null> {
  const result = await pb.collection("chat_messages").getList(1, 1, {
    sort: "-created"
  });
  const record = result.items[0];
  if (!record) {
    return null;
  }
  const threadId = String((record as any).threadId || "").trim();
  return threadId || null;
}

function mapChatRecord(item: any, fallbackThreadId: string): ClawChatMessage {
  return {
    id: String(item.id || ""),
    threadId: String(item.threadId || fallbackThreadId),
    role:
      item.role === "assistant" || item.role === "system" ? item.role : "user",
    content: String(item.content || ""),
    status: String(item.status || "done"),
    error: item.error ? String(item.error) : undefined,
    source: item.source ? String(item.source) : undefined,
    replyToId: item.replyToId ? String(item.replyToId) : undefined,
    created: String(item.createdAtClient || item.created || ""),
    updated: String(item.updated || "")
  };
}

export async function listClawChatMessagesViaGateway(
  threadId: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<ClawChatMessage[]> {
  const params = new URLSearchParams({ threadId, limit: "200" });
  const res = await fetch(
    resolveGatewayEndpoint(`/api/chat/messages?${params.toString()}`, gatewayBaseUrl),
    {
    headers: bearerToken
      ? { Authorization: `Bearer ${bearerToken}` }
      : undefined
    }
  );
  const text = await res.text();
  let data: any = {};
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    // leave as text for error path
  }
  if (!res.ok) {
    const msg =
      typeof data === "object" && data?.error
        ? String(data.error)
        : `Gateway chat list failed (${res.status})`;
    throw new Error(msg);
  }
  const items = Array.isArray(data?.items) ? data.items : [];
  return items.map((item: any) => mapChatRecord(item, threadId));
}

export async function getLatestChatThreadViaGateway(
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<string | null> {
  const res = await fetch(
    resolveGatewayEndpoint("/api/chat/latest-thread", gatewayBaseUrl),
    {
      headers: bearerToken
        ? { Authorization: `Bearer ${bearerToken}` }
        : undefined
    }
  );
  const text = await res.text();
  let data: any = {};
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    data = {};
  }
  if (!res.ok) {
    const msg =
      typeof data === "object" && data?.error
        ? String(data.error)
        : `Gateway latest-thread failed (${res.status})`;
    throw new Error(msg);
  }
  const threadId = String(data?.threadId || "").trim();
  return threadId || null;
}

export async function createClawChatUserMessageViaGateway(
  threadId: string,
  content: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
) {
  const res = await fetch(resolveGatewayEndpoint("/api/chat/messages", gatewayBaseUrl), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(bearerToken ? { Authorization: `Bearer ${bearerToken}` } : {})
    },
    body: JSON.stringify({ threadId, content })
  });
  const text = await res.text();
  let data: any = {};
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    // leave as text for error path
  }
  if (!res.ok) {
    const msg =
      typeof data === "object" && data?.error
        ? String(data.error)
        : `Gateway chat send failed (${res.status})`;
    throw new Error(msg);
  }
  return data;
}
