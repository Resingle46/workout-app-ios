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
COACH_INTERNAL_TOKEN=replace-with-internal-token
AI_MODEL=@cf/mistralai/mistral-small-3.1-24b-instruct
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

- `COACH_INTERNAL_TOKEN`

Set runtime vars and bindings in Cloudflare:

- AI binding: `AI`
- `AI_MODEL=@cf/mistralai/mistral-small-3.1-24b-instruct`
- `COACH_PROMPT_VERSION=2026-03-25.v1`

The Worker uses Cloudflare Workers AI directly and does not require an OpenAI API key.

## iOS config

The iOS app reads these values from build settings into `Info.plist`:

- `COACH_FEATURE_ENABLED`
- `COACH_BACKEND_BASE_URL`
- `COACH_INTERNAL_BEARER_TOKEN`

Do not commit real values. Override them only in local/internal build settings.
