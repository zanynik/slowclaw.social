import { AtpAgent } from "@atproto/api";
import type { BlueskyCredentials } from "./types";

export type BlueskySession = {
  accessJwt: string;
  did: string;
  handle: string;
};

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
      did: res.data.did,
      handle: res.data.handle
    } satisfies BlueskySession
  };
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
