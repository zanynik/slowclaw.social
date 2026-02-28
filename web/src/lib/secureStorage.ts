import type { BlueskyCredentials } from "./types";
import type { BlueskySession } from "./bluesky";

const FALLBACK_KEY = "mysky.bluesky.credentials";
const SECRET_SERVICE = "com.example.myskyposter";
const SECRET_ACCOUNT = "bluesky.credentials";
const SESSION_ACCOUNT = "bluesky.session";
const GATEWAY_SECRET_SERVICE = "social.slowclaw.gateway";
const GATEWAY_SECRET_ACCOUNT = "desktop.gateway.token";

type SecretGetResponse = { value: string | null };

function defaultCreds(): BlueskyCredentials {
  return {
    serviceUrl: "https://bsky.social",
    handle: "",
    appPassword: ""
  };
}

export function loadCredentialsFallback(): BlueskyCredentials {
  const raw = localStorage.getItem(FALLBACK_KEY);
  if (!raw) {
    return defaultCreds();
  }

  try {
    const parsed = JSON.parse(raw) as Partial<BlueskyCredentials>;
    return {
      serviceUrl: parsed.serviceUrl || "https://bsky.social",
      handle: parsed.handle || "",
      appPassword: parsed.appPassword || ""
    };
  } catch {
    return defaultCreds();
  }
}

export function saveCredentialsFallback(value: BlueskyCredentials) {
  localStorage.setItem(FALLBACK_KEY, JSON.stringify(value));
}

async function invokeTauri<T>(cmd: string, args: Record<string, unknown>) {
  try {
    const core = await import("@tauri-apps/api/core");
    return await core.invoke<T>(cmd, args);
  } catch {
    return null;
  }
}

export async function loadCredentialsSecure(): Promise<BlueskyCredentials | null> {
  const res = await invokeTauri<SecretGetResponse>("get_secret", {
    req: { service: SECRET_SERVICE, account: SECRET_ACCOUNT }
  });
  if (!res?.value) {
    return null;
  }

  try {
    const parsed = JSON.parse(res.value) as Partial<BlueskyCredentials>;
    return {
      serviceUrl: parsed.serviceUrl || "https://bsky.social",
      handle: parsed.handle || "",
      appPassword: parsed.appPassword || ""
    };
  } catch {
    return null;
  }
}

export async function saveCredentialsSecure(value: BlueskyCredentials) {
  const serialized = JSON.stringify(value);
  const res = await invokeTauri<void>("set_secret", {
    req: { service: SECRET_SERVICE, account: SECRET_ACCOUNT, value: serialized }
  });

  if (res === null) {
    saveCredentialsFallback(value);
  }
}

export async function deleteCredentialsSecure() {
  const res = await invokeTauri<void>("delete_secret", {
    req: { service: SECRET_SERVICE, account: SECRET_ACCOUNT }
  });
  await invokeTauri<void>("delete_secret", {
    req: { service: SECRET_SERVICE, account: SESSION_ACCOUNT }
  });
  localStorage.removeItem(FALLBACK_KEY);
  return res;
}

export async function loadBlueskySessionSecure(): Promise<BlueskySession | null> {
  const res = await invokeTauri<SecretGetResponse>("get_secret", {
    req: { service: SECRET_SERVICE, account: SESSION_ACCOUNT }
  });
  if (!res?.value) {
    return null;
  }
  try {
    const parsed = JSON.parse(res.value) as Partial<BlueskySession>;
    if (!parsed.accessJwt || !parsed.did || !parsed.handle) {
      return null;
    }
    return {
      accessJwt: String(parsed.accessJwt),
      did: String(parsed.did),
      handle: String(parsed.handle)
    };
  } catch {
    return null;
  }
}

export async function saveBlueskySessionSecure(session: BlueskySession): Promise<void> {
  await invokeTauri<void>("set_secret", {
    req: {
      service: SECRET_SERVICE,
      account: SESSION_ACCOUNT,
      value: JSON.stringify(session)
    }
  });
}

export async function loadGatewayTokenSecure(): Promise<string | null> {
  const res = await invokeTauri<SecretGetResponse>("get_secret", {
    req: { service: GATEWAY_SECRET_SERVICE, account: GATEWAY_SECRET_ACCOUNT }
  });
  if (!res?.value || !res.value.trim()) {
    return null;
  }
  return res.value.trim();
}

export async function saveGatewayTokenSecure(token: string): Promise<void> {
  const normalized = token.trim();
  if (!normalized) {
    return;
  }
  await invokeTauri<void>("set_secret", {
    req: {
      service: GATEWAY_SECRET_SERVICE,
      account: GATEWAY_SECRET_ACCOUNT,
      value: normalized
    }
  });
}
