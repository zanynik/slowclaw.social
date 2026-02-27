import type { BlueskyCredentials } from "./types";

const KEY = "mysky.bluesky.credentials";

export function loadCredentials(): BlueskyCredentials {
  const raw = localStorage.getItem(KEY);
  if (!raw) {
    return {
      serviceUrl: "https://bsky.social",
      handle: "",
      appPassword: ""
    };
  }

  try {
    const parsed = JSON.parse(raw) as Partial<BlueskyCredentials>;
    return {
      serviceUrl: parsed.serviceUrl || "https://bsky.social",
      handle: parsed.handle || "",
      appPassword: parsed.appPassword || ""
    };
  } catch {
    return {
      serviceUrl: "https://bsky.social",
      handle: "",
      appPassword: ""
    };
  }
}

export function saveCredentials(value: BlueskyCredentials) {
  localStorage.setItem(KEY, JSON.stringify(value));
}

