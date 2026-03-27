# Coach Worker

Cloudflare Worker backend for the in-app AI Coach.

## Routes

- `GET /health`
- `GET /v1/backup/status?installID=...`
- `PUT /v1/backup`
- `GET /v1/backup/download?installID=...&version=current`
- `POST /v1/backup/restore-decision`
- `DELETE /v1/backup`
- `DELETE /v1/coach/state`
- `PATCH /v1/coach/preferences`
- `POST /v1/coach/memory/clear`
- `POST /v1/coach/profile-insights`
- `POST /v2/coach/chat-jobs`
- `POST /v2/coach/workout-summary-jobs`
- `GET /v2/coach/chat-jobs/:jobID?installID=...`
- `GET /v2/coach/workout-summary-jobs/:jobID?installID=...`

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
- KV binding: `COACH_STATE_KV`
- Workflow binding: `COACH_CHAT_WORKFLOW`
- `AI_MODEL=@cf/mistralai/mistral-small-3.1-24b-instruct`
- `COACH_PROMPT_VERSION=2026-03-25.v1`

The Worker uses Cloudflare Workers AI directly and does not require an OpenAI API key.

`wrangler.jsonc` now declares the Workflow binding, so Cloudflare does not need a separate manual dashboard binding step as long as deploys run through `wrangler deploy`.

## D1 migrations

Production deploys must apply D1 migrations before publishing the Worker. The `deploy` script now does this automatically:

```bash
npm run deploy
```

That runs:

```bash
wrangler d1 migrations apply APP_META_DB --remote
wrangler deploy
```

If you deploy outside this script, make sure all migrations in `migrations/` are applied remotely first.

## Cloudflare KV setup

`wrangler.jsonc` now declares:

```jsonc
"kv_namespaces": [
  {
    "binding": "COACH_STATE_KV"
  }
]
```

With Cloudflare Git / dashboard deploys, this lets Workers automatically provision and keep the KV binding instead of dropping it on the next deploy.

If you want to pin the Worker to an existing namespace instead of auto-provisioning a new one, replace the binding with the explicit namespace ID after you copy it from the Cloudflare dashboard:

```jsonc
"kv_namespaces": [
  {
    "binding": "COACH_STATE_KV",
    "id": "<KV_NAMESPACE_ID>"
  }
]
```

Create a KV namespace in Cloudflare manually only if you want to reuse a specific existing namespace, for example:

- Namespace name: `workoutapp-ai-coach-state`

Then bind that namespace to the Worker with:

- Binding name: `COACH_STATE_KV`

Without `COACH_STATE_KV`, `/health` will return `status: "error"` and coach requests will fail with `server_misconfigured`.

## iOS config

The iOS app reads these values from build settings into `Info.plist`:

- `COACH_FEATURE_ENABLED`
- `COACH_BACKEND_BASE_URL`
- `COACH_INTERNAL_BEARER_TOKEN`

Do not commit real values. Override them only in local/internal build settings.
