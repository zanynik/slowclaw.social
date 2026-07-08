/**
 * profile.ts — localStorage-backed local profile (name / bio / avatar).
 *
 * The Profile tab used to render unsaved `<input defaultValue="">` fields, so
 * typing a name or bio was silently lost on navigation. This module gives the
 * profile first-class local persistence so the Twitter/Instagram-style header
 * (editable name + bio + avatar) actually sticks.
 *
 * Local-only by design: no network, no protocol push, no PII leaves the device.
 * Avatar is stored as a data URL (from a file picker), capped to keep localStorage
 * well under quota. Mirrors the savedItems.ts event pattern so React can subscribe.
 */

export interface LocalProfile {
  name: string;
  bio: string;
  /** Data URL (image/*) or empty string. */
  avatar: string;
  updatedAt: number;
}

const PROFILE_KEY = "slowclaw.profile.v1";
const EVENT_NAME = "slowclaw:profile-change";

/** Soft cap on stored avatar size (data URL chars). ~256KB after base64 inflation. */
const MAX_AVATAR_CHARS = 340_000;

function readJSON<T>(key: string, fallback: T): T {
  if (typeof window === "undefined") return fallback;
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return fallback;
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function write(value: LocalProfile): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(PROFILE_KEY, JSON.stringify(value));
    window.dispatchEvent(new CustomEvent(EVENT_NAME, { detail: { key: PROFILE_KEY } }));
  } catch {
    /* quota error — non-fatal, local-only feature */
  }
}

/** Read the current local profile, or null if never set. */
export function getProfile(): LocalProfile | null {
  const p = readJSON<LocalProfile | null>(PROFILE_KEY, null);
  if (!p) return null;
  // Defensive: ensure shape in case of legacy/corrupt data.
  return {
    name: typeof p.name === "string" ? p.name : "",
    bio: typeof p.bio === "string" ? p.bio : "",
    avatar: typeof p.avatar === "string" ? p.avatar : "",
    updatedAt: typeof p.updatedAt === "number" ? p.updatedAt : 0,
  };
}

/** Merge a partial update into the stored profile (creates if absent). */
export function saveProfile(patch: Partial<Omit<LocalProfile, "updatedAt">>): LocalProfile {
  const current = getProfile();
  const next: LocalProfile = {
    name: patch.name ?? current?.name ?? "",
    bio: patch.bio ?? current?.bio ?? "",
    avatar: patch.avatar ?? current?.avatar ?? "",
    updatedAt: Date.now(),
  };
  write(next);
  return next;
}

/** Replace the avatar (data URL). Pass "" to clear. Over-large inputs are rejected. */
export function setAvatar(dataUrl: string): boolean {
  if (dataUrl && dataUrl.length > MAX_AVATAR_CHARS) return false;
  saveProfile({ avatar: dataUrl });
  return true;
}

/**
 * Read a user-selected image File as a downscaled data URL.
 * Returns null if the file isn't an image or reading fails.
 * Downscaling keeps localStorage within quota for large phone photos.
 */
export async function fileToAvatarDataUrl(file: File, maxDim = 256): Promise<string | null> {
  if (!file.type.startsWith("image/")) return null;
  try {
    const dataUrl = await new Promise<string>((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result || ""));
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(file);
    });
    // Downscale via canvas so we don't blow the localStorage budget.
    const img = await new Promise<HTMLImageElement>((resolve, reject) => {
      const el = new Image();
      el.onload = () => resolve(el);
      el.onerror = () => reject(new Error("image decode failed"));
      el.src = dataUrl;
    });
    const scale = Math.min(1, maxDim / Math.max(img.width, img.height));
    const w = Math.round(img.width * scale);
    const h = Math.round(img.height * scale);
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    if (!ctx) return dataUrl; // fallback: return original
    ctx.drawImage(img, 0, 0, w, h);
    return canvas.toDataURL("image/jpeg", 0.85);
  } catch {
    return null;
  }
}

/** Subscribe to same-tab + cross-tab profile changes. Returns an unsubscribe fn. */
export function onProfileChange(cb: () => void): () => void {
  if (typeof window === "undefined") return () => {};
  const handler = () => cb();
  window.addEventListener(EVENT_NAME, handler);
  window.addEventListener("storage", handler);
  return () => {
    window.removeEventListener(EVENT_NAME, handler);
    window.removeEventListener("storage", handler);
  };
}

/** A sensible display name fallback when no local profile name is set. */
export function displayNameOr(profile: LocalProfile | null, fallback: string): string {
  const n = profile?.name?.trim();
  return n ? n : fallback;
}
