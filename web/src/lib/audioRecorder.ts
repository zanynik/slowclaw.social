/**
 * audioRecorder.ts — cross-platform audio recording abstraction.
 *
 * Desktop (macOS/Windows via Tauri): uses the browser's MediaRecorder API.
 * Mobile (iOS/Android via Tauri): invokes native Tauri plugin commands
 *   that use AVAudioSession (iOS) / ForegroundService + MediaRecorder (Android).
 *   The native plugin keeps recording alive when the screen locks.
 *
 * Usage:
 *   const state = await startRecording();
 *   const blob  = await stopRecording();    // Blob of audio/webm or audio/m4a
 *   await saveJournalMedia("audio", "recording.webm", blobToB64(blob));
 */

import { invoke } from "@tauri-apps/api/core";

// Detect Tauri mobile context at runtime
function isMobile(): boolean {
  if (typeof window === "undefined") return false;
  // Tauri sets __TAURI_MOBILE__ on mobile builds
  return (
    (window as any).__TAURI_MOBILE__ === true ||
    /iphone|ipad|android/i.test(navigator.userAgent)
  );
}

// ─────────────────────────────────────────────
// State
// ─────────────────────────────────────────────

export type RecordingState = "idle" | "recording" | "paused";

let _mediaRecorder: MediaRecorder | null = null;
let _chunks: BlobPart[] = [];
let _resolveStop: ((blob: Blob) => void) | null = null;
let _state: RecordingState = "idle";

export function getRecordingState(): RecordingState {
  return _state;
}

// ─────────────────────────────────────────────
// Desktop implementation (MediaRecorder)
// ─────────────────────────────────────────────

async function startDesktop(): Promise<RecordingState> {
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
  _chunks = [];
  _mediaRecorder = new MediaRecorder(stream);

  _mediaRecorder.ondataavailable = (e) => {
    if (e.data.size > 0) _chunks.push(e.data);
  };

  _mediaRecorder.onstop = () => {
    const blob = new Blob(_chunks, { type: _mediaRecorder?.mimeType || "audio/webm" });
    _chunks = [];
    if (_resolveStop) {
      _resolveStop(blob);
      _resolveStop = null;
    }
    // Stop all tracks so the microphone indicator disappears
    stream.getTracks().forEach((t) => t.stop());
  };

  _mediaRecorder.start(250); // collect in 250ms chunks
  _state = "recording";
  return "recording";
}

async function stopDesktop(): Promise<Blob> {
  return new Promise((resolve, reject) => {
    if (!_mediaRecorder || _mediaRecorder.state === "inactive") {
      reject(new Error("No active recording"));
      return;
    }
    _resolveStop = resolve;
    _mediaRecorder.stop();
    _state = "idle";
  });
}

// ─────────────────────────────────────────────
// Mobile implementation (native Tauri plugin)
//
// The native plugin is implemented in:
//   iOS:     src-tauri/ios/Sources/AudioRecorderPlugin/AudioRecorderPlugin.swift
//   Android: src-tauri/android/src/main/kotlin/.../AudioRecorderPlugin.kt
//
// Both use background-capable audio recording that survives screen lock.
// ─────────────────────────────────────────────

async function startMobile(): Promise<RecordingState> {
  await invoke("plugin:audio_recorder|start_recording");
  _state = "recording";
  return "recording";
}

async function stopMobile(): Promise<Blob> {
  const result = await invoke<{ path: string; mimeType: string }>(
    "plugin:audio_recorder|stop_recording"
  );
  // Read the file back as bytes via Tauri fs plugin
  const { readFile } = await import("@tauri-apps/plugin-fs");
  const bytes = await readFile(result.path);
  _state = "idle";
  return new Blob([bytes], { type: result.mimeType || "audio/m4a" });
}

// ─────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────

export async function startRecording(): Promise<RecordingState> {
  if (_state === "recording") return "recording";
  if (isMobile()) {
    return startMobile();
  }
  return startDesktop();
}

export async function stopRecording(): Promise<Blob> {
  if (isMobile()) {
    return stopMobile();
  }
  return stopDesktop();
}

/** Convert a Blob to a base64 string (for saveJournalMedia). */
export function blobToBase64(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const result = reader.result as string;
      // Strip the data URL prefix robustly, even when MIME params contain commas.
      const marker = ";base64,";
      const markerIndex = result.indexOf(marker);
      if (markerIndex >= 0) {
        resolve(result.slice(markerIndex + marker.length).trim());
        return;
      }
      const commaIndex = result.lastIndexOf(",");
      resolve((commaIndex >= 0 ? result.slice(commaIndex + 1) : result).trim());
    };
    reader.onerror = reject;
    reader.readAsDataURL(blob);
  });
}
