import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const tauriDevHost = process.env.TAURI_DEV_HOST;
const configuredBase = process.env.SLOWCLAW_WEB_BASE;
// When SLOWCLAW_DEMO=1 the web build becomes a read-only, sample-data demo
// served from the marketing site (e.g. slowclaw.social/app/). It seeds sample
// journals/posts/todos and never expects a reachable gateway backend.
const demoBuild = process.env.SLOWCLAW_DEMO === "1";

export default defineConfig({
  // Gateway embed expects "/_app/"; Tauri builds should use relative assets ("./");
  // the public demo is served at "/app/".
  base: configuredBase && configuredBase.trim() ? configuredBase.trim() : "/_app/",
  plugins: [react()],
  define: {
    __SLOWCLAW_DEMO_BUILD__: JSON.stringify(demoBuild),
  },
  clearScreen: false,
  build: {
    outDir: "dist"
  },
  server: {
    port: 1420,
    strictPort: true,
    host: tauriDevHost || "0.0.0.0",
    hmr: tauriDevHost
      ? {
          protocol: "ws",
          host: tauriDevHost,
          port: 1421
        }
      : undefined
  }
});
