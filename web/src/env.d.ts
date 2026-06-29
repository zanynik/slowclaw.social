// Build-time flag injected by vite.config.ts (`define`). When SLOWCLAW_DEMO=1 the
// web build is a read-only, sample-data demo served from the marketing site. The
// value is replaced literally at build time, so it is a plain boolean constant.
declare const __SLOWCLAW_DEMO_BUILD__: boolean;
