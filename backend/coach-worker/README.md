# Coach Worker

Cloudflare Worker backend for the in-app AI Coach.

## Routes

- `GET /health`
- `POST /v1/coach/profile-insights`
- `POST /v1/coach/chat`

All `POST` routes require:

```txt
Authorization: Bearer <COACH_INTERNAL_TOKEN>
```

## Local setup

1. Open `backend/coach-worker`.
2. Install dependencies:

```bash
npm install
```

3. Create `.dev.vars` in this folder:

```txt
OPENAI_API_KEY=sk-...
COACH_INTERNAL_TOKEN=replace-with-internal-token
OPENAI_MODEL=gpt-5-mini
COACH_PROMPT_VERSION=2026-03-25.v1
```

4. Start the worker locally:

```bash
npm run dev
```

## Checks

```bash
npm run typecheck
npm test
```

## Cloudflare Git integration

Configure the Worker in Cloudflare with:

- Repository: this repo
- Production branch: `main`
- Root directory: `backend/coach-worker`
- Build command: empty
- Deploy command: `npm run deploy`

Set runtime secrets in Cloudflare:

- `OPENAI_API_KEY`
- `COACH_INTERNAL_TOKEN`

Set runtime vars in Cloudflare:

- `OPENAI_MODEL=gpt-5-mini`
- `COACH_PROMPT_VERSION=2026-03-25.v1`

## iOS config

The iOS app reads these values from build settings into `Info.plist`:

- `COACH_FEATURE_ENABLED`
- `COACH_BACKEND_BASE_URL`
- `COACH_INTERNAL_BEARER_TOKEN`

Do not commit real values. Override them only in local/internal build settings.
