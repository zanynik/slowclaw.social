import type { LibraryItem } from "./types";

function authHeaders(token?: string, contentType?: string): HeadersInit {
  return {
    ...(contentType ? { "Content-Type": contentType } : {}),
    ...(token ? { Authorization: `Bearer ${token}` } : {})
  };
}

async function parseJsonOrThrow(res: Response) {
  const text = await res.text();
  let data: any = {};
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    data = { raw: text };
  }
  if (!res.ok) {
    throw new Error(String(data?.error || `Request failed (${res.status})`));
  }
  return data;
}

export async function pairGatewayClient(oneTimeCode: string) {
  const code = oneTimeCode.trim();
  if (!code) {
    throw new Error("Pairing code is required");
  }
  const res = await fetch("/pair", {
    method: "POST",
    headers: {
      "X-Pairing-Code": code
    }
  });
  const data = await parseJsonOrThrow(res);
  return {
    token: String(data?.token || ""),
    message: String(data?.message || ""),
    paired: Boolean(data?.paired)
  };
}

export async function listLibraryItems(
  scope: "all" | "journal" | "feed",
  bearerToken?: string
): Promise<LibraryItem[]> {
  const params = new URLSearchParams({ scope, limit: "400" });
  const res = await fetch(`/api/library/items?${params}`, {
    headers: authHeaders(bearerToken)
  });
  const data = await parseJsonOrThrow(res);
  return Array.isArray(data.items) ? (data.items as LibraryItem[]) : [];
}

export async function readLibraryText(path: string, bearerToken?: string): Promise<string> {
  const params = new URLSearchParams({ path });
  const res = await fetch(`/api/library/text?${params}`, {
    headers: authHeaders(bearerToken)
  });
  const data = await parseJsonOrThrow(res);
  return String(data.content || "");
}

export async function saveLibraryText(
  path: string,
  content: string,
  bearerToken?: string
): Promise<void> {
  const res = await fetch("/api/library/save-text", {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({ path, content })
  });
  await parseJsonOrThrow(res);
}

export async function createJournalTextViaGateway(
  title: string,
  content: string,
  bearerToken?: string
) {
  const res = await fetch("/api/journal/text", {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({ title, content, source: "mobile-ui" })
  });
  return parseJsonOrThrow(res);
}

export async function uploadMediaViaGateway(
  file: Blob,
  options: { kind: "audio" | "video" | "image" | "file"; filename: string; title?: string; entryId?: string },
  bearerToken?: string
) {
  const params = new URLSearchParams({
    kind: options.kind,
    filename: options.filename
  });
  if (options.title) {
    params.set("title", options.title);
  }
  if (options.entryId) {
    params.set("entry_id", options.entryId);
  }
  const res = await fetch(`/api/media/upload?${params}`, {
    method: "POST",
    headers: authHeaders(bearerToken, file.type || "application/octet-stream"),
    body: file
  });
  return parseJsonOrThrow(res);
}

export async function fetchMediaAsFile(
  mediaUrl: string,
  filename: string,
  bearerToken?: string
): Promise<File> {
  const res = await fetch(mediaUrl, { headers: authHeaders(bearerToken) });
  if (!res.ok) {
    throw new Error(`Failed to fetch media (${res.status})`);
  }
  const blob = await res.blob();
  return new File([blob], filename, { type: blob.type || "application/octet-stream" });
}
