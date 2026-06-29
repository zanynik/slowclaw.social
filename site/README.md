# slowclaw.social — marketing site

The public landing page for SlowClaw. Pure static HTML/CSS/JS — no build step for the
site itself. It is assembled with the built web app and deployed together to GitHub
Pages (see `.github/workflows/deploy-site.yml`).

## Layout of the deployed site

```
/               ← this marketing site (index.html, styles.css, script.js, images/)
/app/           ← the live web demo (built from ../web with SLOWCLAW_DEMO=1)
/CNAME          ← custom apex domain (slowclaw.social)
```

The "Try the live demo" buttons link to `/app/`, which serves a read-only, sample-data
build of the real app so visitors can click around and feel the product without
installing anything or standing up the gateway.

## Local preview

```bash
python3 -m http.server 8081
# visit http://127.0.0.1:8081/
```

To preview the marketing site *with* the live demo, build the demo app and serve it
under `/app/`:

```bash
cd ../web
npm install
SLOWCLAW_DEMO=1 SLOWCLAW_WEB_BASE=/app/ npm run build
# serve ../site as root with web/dist mounted at /app/
```

## Editing

- `index.html` — page content and structure
- `styles.css` — theme tokens + component styles (dark glassmorphism)
- `script.js` — terminal animation, reveal-on-scroll, mobile menu, smooth scroll
- `images/` — product screenshots

Keep the copy aligned with the actual product (an iOS + macOS local-first journaling
app with on-device AI) and the repo's `AGENTS.md` / `docs/vision-contract.md`.
