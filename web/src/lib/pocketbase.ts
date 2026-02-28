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
