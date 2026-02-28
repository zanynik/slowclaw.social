import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const tauriDevHost = process.env.TAURI_DEV_HOST;
const configuredBase = process.env.SLOWCLAW_WEB_BASE;

export default defineConfig({
  // Gateway embed expects "/_app/"; Tauri builds should use relative assets ("./").
  base: configuredBase && configuredBase.trim() ? configuredBase.trim() : "/_app/",
  plugins: [react()],
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
