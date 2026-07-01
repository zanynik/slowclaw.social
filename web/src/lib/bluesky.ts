import { AtpAgent } from "@atproto/api";
import type { BlueskyCredentials } from "./types";

export type BlueskySession = {
  accessJwt: string;
  refreshJwt: string;
  did: string;
  handle: string;
};

/**
 * Public (anonymous) Bluesky AppView base URL. Reads of PUBLIC posts do NOT
 * require auth — this is a permissionless source per the open-web design. We
 * use `api.bsky.app` (Bluesky's public AppView) which serves searchPosts /
 * getAuthorFeed / getFeed without a session. CORS-enabled for browser use.
 */
export const BLUESKY_PUBLIC_APPVIEW = "https://api.bsky.app";


export function createAgent(serviceUrl: string) {
  return new AtpAgent({ service: serviceUrl });
}

export async function loginBluesky(creds: BlueskyCredentials) {
  const agent = createAgent(creds.serviceUrl);
  const res = await agent.login({
    identifier: creds.handle,
    password: creds.appPassword
  });

  return {
    agent,
    session: {
      accessJwt: res.data.accessJwt,
      refreshJwt: res.data.refreshJwt,
      did: res.data.did,
      handle: res.data.handle
    } satisfies BlueskySession
  };
}

export async function refreshBlueskySession(
  serviceUrl: string,
  refreshJwt: string
): Promise<{ agent: AtpAgent; session: BlueskySession }> {
  const baseUrl = serviceUrl.replace(/\/+$/, "");
  const res = await fetch(`${baseUrl}/xrpc/com.atproto.server.refreshSession`, {
    method: "POST",
    headers: { Authorization: `Bearer ${refreshJwt}` }
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Token refresh failed (${res.status}): ${text}`);
  }
  const data = await res.json();
  const agent = createAgent(serviceUrl);
  await agent.resumeSession({
    accessJwt: data.accessJwt,
    refreshJwt: data.refreshJwt,
    did: data.did,
    handle: data.handle,
    active: true
  });
  return {
    agent,
    session: {
      accessJwt: data.accessJwt,
      refreshJwt: data.refreshJwt,
      did: data.did,
      handle: data.handle
    }
  };
}

export function isExpiredTokenError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  return /ExpiredToken|token.*expir/i.test(error.message);
}

export async function likeBlueskyPost(
  agent: AtpAgent,
  did: string,
  postUri: string,
  postCid: string
): Promise<{ uri: string; cid: string }> {
  const res = await agent.com.atproto.repo.createRecord({
    repo: did,
    collection: "app.bsky.feed.like",
    record: {
      $type: "app.bsky.feed.like",
      subject: { uri: postUri, cid: postCid },
      createdAt: new Date().toISOString()
    }
  });
  return res.data;
}

export async function unlikeBlueskyPost(agent: AtpAgent, likeUri: string) {
  const rkey = likeUri.split("/").pop() || "";
  const repo = likeUri.replace("at://", "").split("/")[0];
  await agent.com.atproto.repo.deleteRecord({
    repo,
    collection: "app.bsky.feed.like",
    rkey
  });
}

export async function fetchBlueskyThread(
  serviceUrl: string,
  accessJwt: string,
  postUri: string,
  depth = 6
): Promise<any> {
  const baseUrl = serviceUrl.replace(/\/+$/, "");
  const url = `${baseUrl}/xrpc/app.bsky.feed.getPostThread?uri=${encodeURIComponent(postUri)}&depth=${depth}&parentHeight=0`;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${accessJwt}` }
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Failed to fetch thread (${res.status}): ${text}`);
  }
  return await res.json();
}

export async function replyToBlueskyPost(
  agent: AtpAgent,
  did: string,
  text: string,
  parentUri: string,
  parentCid: string,
  rootUri: string,
  rootCid: string
): Promise<{ uri: string; cid: string }> {
  const res = await agent.com.atproto.repo.createRecord({
    repo: did,
    collection: "app.bsky.feed.post",
    record: {
      $type: "app.bsky.feed.post",
      text,
      reply: {
        root: { uri: rootUri, cid: rootCid },
        parent: { uri: parentUri, cid: parentCid }
      },
      createdAt: new Date().toISOString()
    }
  });
  return res.data;
}

export async function postTextToBluesky(
  agent: AtpAgent,
  did: string,
  text: string
) {
  const now = new Date().toISOString();
  const res = await agent.com.atproto.repo.createRecord({
    repo: did,
    collection: "app.bsky.feed.post",
    record: {
      $type: "app.bsky.feed.post",
      text,
      createdAt: now
    }
  });

  return res.data;
}

export async function postVideoToBluesky(
  agent: AtpAgent,
  serviceUrl: string,
  accessJwt: string,
  did: string,
  text: string,
  videoFile: File,
  alt = "",
  onProgress?: (progress: { stage: string; percent: number; message: string }) => void
) {
  onProgress?.({ stage: "prepare", percent: 5, message: "Preparing video upload..." });
  const videoBlob = await uploadVideoViaBlueskyService({
    agent,
    serviceUrl,
    accessJwt,
    did,
    file: videoFile,
    onProgress
  });
  onProgress?.({ stage: "publishing", percent: 90, message: "Publishing post..." });
  const aspectRatio = await getVideoAspectRatio(videoFile);

  const now = new Date().toISOString();
  const res = await agent.com.atproto.repo.createRecord({
    repo: did,
    collection: "app.bsky.feed.post",
    record: {
      $type: "app.bsky.feed.post",
      text,
      createdAt: now,
      embed: {
        $type: "app.bsky.embed.video",
        video: videoBlob,
        alt,
        ...(aspectRatio ? { aspectRatio } : {})
      }
    } as Record<string, unknown>
  });
  onProgress?.({ stage: "done", percent: 100, message: "Posted to Bluesky." });

  return res.data;
}

type VideoUploadArgs = {
  agent: AtpAgent;
  serviceUrl: string;
  accessJwt: string;
  did: string;
  file: File;
  onProgress?: (progress: { stage: string; percent: number; message: string }) => void;
};

type VideoJobStatus = {
  state?: string;
  progress?: number;
  error?: string;
  blob?: unknown;
  jobStatus?: {
    state?: string;
    progress?: number;
    error?: string;
    blob?: unknown;
  };
};

async function uploadVideoViaBlueskyService(args: VideoUploadArgs) {
  const serviceAuth = await args.agent.com.atproto.server.getServiceAuth({
    aud: getPdsDidAudienceFromAccessJwt(args.accessJwt) || `did:web:${new URL(args.serviceUrl).host}`,
    lxm: "com.atproto.repo.uploadBlob",
    exp: Math.floor(Date.now() / 1000) + 60 * 30
  });

  const uploadUrl = new URL("https://video.bsky.app/xrpc/app.bsky.video.uploadVideo");
  uploadUrl.searchParams.set("did", args.did);
  uploadUrl.searchParams.set("name", args.file.name || "video.mp4");

  const uploadRes = await fetch(uploadUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${serviceAuth.data.token}`,
      "Content-Type": args.file.type || "video/mp4"
    },
    body: args.file
  });

  const uploadText = await uploadRes.text();
  let uploadData: Record<string, unknown> = {};
  try {
    uploadData = JSON.parse(uploadText) as Record<string, unknown>;
  } catch {
    throw new Error(`Video upload failed (${uploadRes.status}): ${uploadText}`);
  }

  if (!uploadRes.ok) {
    throw new Error(
      `Video upload failed (${uploadRes.status}): ${
        typeof uploadData.message === "string" ? uploadData.message : uploadText
      }`
    );
  }
  args.onProgress?.({
    stage: "uploaded",
    percent: 30,
    message: "Uploaded video bytes. Waiting for Bluesky processing..."
  });

  if (uploadData.blob) {
    args.onProgress?.({
      stage: "ready",
      percent: 85,
      message: "Video processed."
    });
    return uploadData.blob;
  }

  const jobId = typeof uploadData.jobId === "string" ? uploadData.jobId : null;
  if (!jobId) {
    throw new Error("Video upload service returned no jobId");
  }

  return await pollBlueskyVideoJob({
    serviceAuthToken: serviceAuth.data.token,
    jobId,
    onProgress: args.onProgress
  });
}

function getPdsDidAudienceFromAccessJwt(accessJwt: string) {
  try {
    const [, payload] = accessJwt.split(".");
    if (!payload) {
      return null;
    }
    const normalized = payload.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
    const json = JSON.parse(atob(padded)) as { aud?: unknown };
    return typeof json.aud === "string" ? json.aud : null;
  } catch {
    return null;
  }
}

async function pollBlueskyVideoJob(args: {
  serviceAuthToken: string;
  jobId: string;
  timeoutMs?: number;
  intervalMs?: number;
  onProgress?: (progress: { stage: string; percent: number; message: string }) => void;
}) {
  const timeoutAt = Date.now() + (args.timeoutMs ?? 3 * 60 * 1000);
  const intervalMs = args.intervalMs ?? 1500;

  while (Date.now() < timeoutAt) {
    const url = new URL("https://video.bsky.app/xrpc/app.bsky.video.getJobStatus");
    url.searchParams.set("jobId", args.jobId);

    const res = await fetch(url, {
      headers: {
        Authorization: `Bearer ${args.serviceAuthToken}`
      }
    });

    const text = await res.text();
    let data: VideoJobStatus = {};
    try {
      data = JSON.parse(text) as VideoJobStatus;
    } catch {
      throw new Error(`Video job status parse failed: ${text}`);
    }

    if (!res.ok) {
      throw new Error(
        `Video job status failed (${res.status}): ${typeof data.error === "string" ? data.error : text}`
      );
    }

    const status = data.jobStatus ?? data;
    const state = status.state ?? "";
    const rawProgress =
      typeof status.progress === "number"
        ? status.progress
        : typeof data.progress === "number"
          ? data.progress
          : undefined;
    const normalizedProgress =
      rawProgress == null
        ? undefined
        : rawProgress > 1
          ? Math.max(0, Math.min(100, Math.round(rawProgress)))
          : Math.max(0, Math.min(100, Math.round(rawProgress * 100)));
    if (normalizedProgress != null) {
      args.onProgress?.({
        stage: "processing",
        percent: Math.max(30, Math.min(88, normalizedProgress)),
        message: `Bluesky processing: ${normalizedProgress}%`
      });
    }
    if (status.blob) {
      args.onProgress?.({
        stage: "ready",
        percent: 88,
        message: "Video processing complete."
      });
      return status.blob;
    }
    if (/completed/i.test(state)) {
      throw new Error("Video job completed but no blob was returned");
    }
    if (/failed|error/i.test(state)) {
      throw new Error(status.error || `Video processing failed (${state})`);
    }

    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }

  throw new Error("Timed out waiting for Bluesky video processing");
}

async function getVideoAspectRatio(file: File) {
  if (typeof document === "undefined") {
    return undefined;
  }

  return await new Promise<{ width: number; height: number } | undefined>((resolve) => {
    const objectUrl = URL.createObjectURL(file);
    const video = document.createElement("video");
    video.preload = "metadata";
    video.onloadedmetadata = () => {
      const width = Math.max(1, Math.round(video.videoWidth || 0));
      const height = Math.max(1, Math.round(video.videoHeight || 0));
      URL.revokeObjectURL(objectUrl);
      resolve(width && height ? { width, height } : undefined);
    };
    video.onerror = () => {
      URL.revokeObjectURL(objectUrl);
      resolve(undefined);
    };
    video.src = objectUrl;
  });
}

export async function sendAuthedXrpcRequest(args: {
  serviceUrl: string;
  accessJwt: string;
  method: "GET" | "POST";
  url: string;
  headers?: Record<string, string>;
  body?: unknown;
}) {
  const headers: Record<string, string> = {
    ...(args.headers || {})
  };

  if (args.body !== undefined && !headers["Content-Type"]) {
    headers["Content-Type"] = "application/json";
  }
  if (!headers.Authorization) {
    headers.Authorization = `Bearer ${args.accessJwt}`;
  }

  const target = args.url.startsWith("http")
    ? args.url
    : `${args.serviceUrl.replace(/\/+$/, "")}/${args.url.replace(/^\/+/, "")}`;

  const res = await fetch(target, {
    method: args.method,
    headers,
    body: args.body === undefined ? undefined : JSON.stringify(args.body)
  });

  const text = await res.text();
  let parsed: unknown = text;
  try {
    parsed = JSON.parse(text);
  } catch {
    // keep text response
  }

  return {
    ok: res.ok,
    status: res.status,
    statusText: res.statusText,
    data: parsed
  };
}

/* ── Anonymous (permissionless) public reads ─────────────────────────────────
 * These call the public Bluesky AppView with NO session token. They power the
 * social Feed / Media tabs as an open-protocol source alongside Nostr. All
 * return plain data shapes (no AtpAgent) so the UI can normalize them via
 * UnifiedItem without depending on auth state.
 * ────────────────────────────────────────────────────────────────────────── */

/** A minimal, plain view of a public Bluesky post (subset we render). */
export type BlueskyPublicPost = {
  uri: string;
  cid: string;
  author: {
    did: string;
    handle: string;
    displayName?: string | null;
    avatar?: string | null;
  };
  record: {
    text: string;
    createdAt: string;
    langs?: string[];
    reply?: { root?: { uri: string }; parent?: { uri: string } };
  };
  embed?: {
    $type?: string;
    images?: Array<{ thumb?: string; fullsize?: string; alt?: string }>;
    video?: string | null;
    playlists?: unknown;
    external?: { uri: string; title?: string; description?: string; thumb?: string };
  };
  likeCount?: number;
  repostCount?: number;
  replyCount?: number;
  indexedAt: string;
};

type BlueskyFetchOpts = { limit?: number; signal?: AbortSignal };

async function blueskyPublicGet<T>(path: string, params: Record<string, string>, opts: BlueskyFetchOpts = {}): Promise<T> {
  const url = new URL(BLUESKY_PUBLIC_APPVIEW + "/xrpc/" + path);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const res = await fetch(url.toString(), {
    method: "GET",
    headers: {
      // AppView requires a non-empty UA and an Accept header.
      "Accept": "application/json",
      "User-Agent": "slowclaw-social/1.0",
    },
    signal: opts.signal,
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`Bluesky ${path} ${res.status}: ${body.slice(0, 200)}`);
  }
  return (await res.json()) as T;
}

/** Epoch seconds from an ISO timestamp (Bluesky uses ISO-8601 `indexedAt`). */
function epochFromIso(iso: string): number {
  const t = Date.parse(iso);
  return Number.isFinite(t) ? Math.floor(t / 1000) : 0;
}

/**
 * LEVER: Bluesky full-text search (most reliable content lever). Searches ALL
 * public posts for `query` server-side via the AppView. Works for ANY term and
 * returns constant traffic for popular queries (AI, tech, art, ...). Anonymous.
 */
export async function searchPublicBlueskyPosts(
  query: string,
  opts: BlueskyFetchOpts = {}
): Promise<BlueskyPublicPost[]> {
  const q = query.trim();
  if (!q) return [];
  const limit = Math.min(opts.limit ?? 25, 100);
  const data = await blueskyPublicGet<{ posts: BlueskyPublicPost[] }>(
    "app.bsky.feed.searchPosts",
    { q, limit: String(limit), sort: "latest" },
    opts,
  );
  return data.posts || [];
}

/**
 * Recent posts by a single actor (handle or DID). Anonymous. Useful for the
 * "follow specific authors" lever later.
 */
export async function getPublicBlueskyAuthorFeed(
  actor: string,
  opts: BlueskyFetchOpts = {}
): Promise<BlueskyPublicPost[]> {
  if (!actor.trim()) return [];
  const limit = Math.min(opts.limit ?? 30, 100);
  const data = await blueskyPublicGet<{ feed: Array<{ post: BlueskyPublicPost }> }>(
    "app.bsky.feed.getAuthorFeed",
    { actor, limit: String(limit) },
    opts,
  );
  return (data.feed || []).map((f) => f.post);
}

/**
 * Resolve a handle to a DID (needed to build feed URIs). Anonymous.
 */
export async function resolveBlueskyHandle(handle: string, opts: BlueskyFetchOpts = {}): Promise<string | null> {
  const h = handle.trim().replace(/^@/, "");
  if (!h) return null;
  try {
    const data = await blueskyPublicGet<{ did: string }>(
      "com.atproto.identity.resolveHandle",
      { handle: h },
      opts,
    );
    return data.did || null;
  } catch {
    return null;
  }
}

/** Convenience: epoch seconds from a BlueskyPublicPost. */
export function blueskyPostTimestamp(post: BlueskyPublicPost): number {
  return epochFromIso(post.indexedAt || post.record?.createdAt || "");
}
