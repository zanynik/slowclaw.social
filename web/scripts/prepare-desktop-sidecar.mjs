import { spawn } from "node:child_process";
import { chmod, copyFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const webDir = path.resolve(scriptDir, "..");
const repoRoot = path.resolve(webDir, "..");
const tauriDir = path.join(webDir, "src-tauri");
const binaryStem = "slowclaw";
const binaryName = process.platform === "win32" ? `${binaryStem}.exe` : binaryStem;
const desktopTargetTriple = await resolveTargetTriple();

if (desktopTargetTriple && isMobileTarget(desktopTargetTriple)) {
  console.log(`[desktop-sidecar] skipping backend bundle for mobile target ${desktopTargetTriple}`);
  process.exit(0);
}

const profile = resolveProfile();
const cargoArgs = [
  "build",
  "--manifest-path",
  path.join(repoRoot, "Cargo.toml"),
  "--bin",
  binaryStem,
];
if (profile === "release") {
  cargoArgs.push("--release");
}
if (desktopTargetTriple) {
  cargoArgs.push("--target", desktopTargetTriple);
}

console.log(
  `[desktop-sidecar] building ${binaryName} (${profile}${desktopTargetTriple ? `, ${desktopTargetTriple}` : ""})`,
);
await run("cargo", cargoArgs, { cwd: repoRoot });

const builtBinary = path.join(
  repoRoot,
  "target",
  ...(desktopTargetTriple ? [desktopTargetTriple] : []),
  profile,
  binaryName,
);
const sidecarBinary = path.join(
  tauriDir,
  "binaries",
  `${binaryStem}-${desktopTargetTriple ?? hostFallbackTriple()}${process.platform === "win32" ? ".exe" : ""}`,
);

await mkdir(path.dirname(sidecarBinary), { recursive: true });
await copyFile(builtBinary, sidecarBinary);
if (process.platform !== "win32") {
  await chmod(sidecarBinary, 0o755);
}

console.log(`[desktop-sidecar] copied ${builtBinary} -> ${sidecarBinary}`);

function resolveProfile() {
  const value = (process.env.SLOWCLAW_BACKEND_PROFILE ?? "release").trim().toLowerCase();
  return value === "debug" ? "debug" : "release";
}

function isMobileTarget(targetTriple) {
  return targetTriple.includes("apple-ios") || targetTriple.includes("android");
}

async function resolveTargetTriple() {
  const explicitTarget =
    process.env.TAURI_ENV_TARGET_TRIPLE ??
    process.env.CARGO_BUILD_TARGET ??
    process.env.TARGET ??
    "";
  if (explicitTarget.trim()) {
    return explicitTarget.trim();
  }

  const rustcVersion = await capture("rustc", ["-vV"], { cwd: repoRoot });
  const hostLine = rustcVersion
    .split(/\r?\n/)
    .find((line) => line.startsWith("host:"));
  return hostLine?.split(":")[1]?.trim() ?? "";
}

function hostFallbackTriple() {
  if (process.platform === "darwin") {
    return process.arch === "arm64" ? "aarch64-apple-darwin" : "x86_64-apple-darwin";
  }
  if (process.platform === "win32") {
    return process.arch === "arm64" ? "aarch64-pc-windows-msvc" : "x86_64-pc-windows-msvc";
  }
  if (process.platform === "linux") {
    return process.arch === "arm64" ? "aarch64-unknown-linux-gnu" : "x86_64-unknown-linux-gnu";
  }
  throw new Error(`unsupported host platform: ${process.platform}`);
}

function run(command, args, options) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      ...options,
      env: process.env,
      stdio: "inherit",
    });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(new Error(`${command} exited with code ${code ?? "unknown"}`));
    });
  });
}

function capture(command, args, options) {
  return new Promise((resolve, reject) => {
    let stdout = "";
    let stderr = "";
    const child = spawn(command, args, {
      ...options,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) {
        resolve(stdout);
        return;
      }
      reject(new Error(`${command} exited with code ${code ?? "unknown"}: ${stderr.trim()}`));
    });
  });
}
