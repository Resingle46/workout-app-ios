# WorkoutApp iOS

A SwiftUI-based workout tracking app for iPhone with a companion Cloudflare Worker backend for AI coaching, cloud backup reconciliation, and async coach/workout-summary jobs.

This repository contains **both sides of the product**:

- a native **iOS client** for planning and logging workouts
- a **Cloudflare Worker backend** that powers AI Coach, remote backup metadata, and long-running coach jobs

The project is designed so the app remains useful as a **local-first workout tracker**, while remote services can be enabled when you want AI and cloud sync.

## What the app does

WorkoutApp helps you manage your training workflow end to end:

- build and edit workout programs
- browse a searchable exercise catalog grouped by category
- run an active workout with timer-like session flow and set logging
- use supersets in workout templates
- review workout history and exercise progress charts
- maintain a user profile with training goals and body metrics
- get AI-generated profile insights and coach responses
- keep local backups and optionally sync state through the backend

The UI is localized for **English and Russian** and currently targets **iPhone** with a dark-first visual design.

## Core features

### iOS app
- **Programs**: create multi-workout programs and edit workout templates
- **Exercise catalog**: seed exercise library plus custom exercises
- **Active workout flow**: log completed sets, reps, and weight during a session
- **Superset support**: template-level grouping with normalization of paired set counts
- **Statistics**: per-exercise charting and historical summaries
- **Profile insights**: progress, consistency, PR, goal, metabolism, and recommendation summaries
- **Coach tab**: AI profile insights, quick prompts, and chat
- **Local persistence**: snapshot-based storage on-device
- **Local backups**: export/restore through Files folder access
- **Cloud sync**: optional backup reconciliation and restore flow against backend state

### Backend
- **Health endpoint**
- **Coach snapshot sync**
- **Profile insights generation**
- **Chat**
- **Async chat jobs**
- **Async workout summary jobs**
- **Backup reconcile / upload / download**
- **Coach preferences update**
- **Remote state deletion**
- **Caching and job state management** using Cloudflare services

## Architecture overview

### 1) iOS: local-first application state
The app centers around `AppStore`, which owns:

- exercise categories and exercises
- programs and workout templates
- active workout session
- workout history
- user profile
- coach analysis settings

State is serialized into a local JSON snapshot, so the app can work without a backend for the core training flow.

### 2) iOS: coach and cloud sync layer
The coach/cloud path is split into dedicated stores:

- `CoachStore` handles profile insights, coach chat, polling, resume logic, and coach preferences
- `CloudSyncStore` handles backup reconciliation and server-side context readiness
- `WorkoutSummaryStore` handles async workout summary generation
- `CoachContextBuilder` compacts app state into a coach-friendly payload

The client can either:

- send an **inline compact snapshot**
- or rely on **server-side context** when the backend already has the required synchronized backup state

### 3) Backend: Cloudflare Worker
The backend lives under `backend/coach-worker` and exposes HTTP endpoints for the iOS app.

It uses:

- **Workers AI** for inference
- **KV** for coach state and cache-like data
- **R2** for remote backup objects
- **D1** for metadata and job coordination
- **Cloudflare Workflows** for async chat and workout summary jobs

This lets the app offload long-running coach operations from the device while keeping a clean API contract.

## Repository structure

```text
.
├── .github/
│   └── workflows/
│       └── ios-build.yml
├── WorkoutApp.xcodeproj/
├── WorkoutApp/
│   ├── Models/
│   │   └── Models.swift
│   ├── Store/
│   │   ├── AppStore.swift
│   │   ├── BackupCoordinator.swift
│   │   └── SeedData.swift
│   ├── Views/
│   │   ├── RootTabView.swift
│   │   ├── ProgramsView.swift
│   │   ├── ActiveWorkoutView.swift
│   │   ├── StatisticsView.swift
│   │   ├── ProfileView.swift
│   │   └── WorkoutTemplateDetailView.swift
│   ├── Resources/
│   │   ├── Info.plist
│   │   ├── en.lproj/Localizable.strings
│   │   ├── ru.lproj/Localizable.strings
│   │   └── Fonts/
│   ├── Assets.xcassets/
│   ├── CoachFeature.swift
│   ├── WorkoutSummaryFeature.swift
│   ├── DeveloperMenuFeature.swift
│   ├── DebugDiagnostics.swift
│   └── WorkoutAppApp.swift
├── WorkoutAppTests/
│   ├── BackupCoordinatorTests.swift
│   ├── WorkoutSummaryFeatureTests.swift
│   └── DebugDiagnosticsTests.swift
└── backend/
    └── coach-worker/
        ├── src/
        ├── migrations/
        ├── test/
        ├── package.json
        ├── wrangler.jsonc
        └── README.md
```

## Tech stack

### iOS
- Swift
- SwiftUI
- Observation
- Foundation / URLSession
- Xcode project (no package manager setup required for the iOS target)

### Backend
- TypeScript
- Cloudflare Workers
- Cloudflare Workers AI
- Cloudflare KV
- Cloudflare R2
- Cloudflare D1
- Cloudflare Workflows
- Zod
- Vitest
- Wrangler

## iOS app setup

### Requirements
- **Xcode 16+**
- **iOS 17+ deployment target**
- Apple signing assets if you want to install on a physical device from Xcode

### Open and run
1. Open `WorkoutApp.xcodeproj` in Xcode.
2. Select the `WorkoutApp` scheme.
3. Set your own **Development Team** and **Bundle Identifier**.
4. Build and run on a simulator or signed device.

### Build-time configuration
The app reads coach configuration through `Info.plist` placeholders backed by build settings:

- `COACH_FEATURE_ENABLED`
- `COACH_BACKEND_BASE_URL`
- `COACH_INTERNAL_BEARER_TOKEN`

Default project values are empty/disabled, so remote coach functionality is off until you configure it.

Do **not** commit real backend tokens.

## Local data model and persistence

The app persists a snapshot that contains:

- `programs`
- `exercises`
- `history`
- `profile`
- `coachAnalysisSettings`

The local snapshot is stored as:

```text
Documents/workout-app-snapshot.json
```

This keeps the product usable even without remote services.

## Backup model

There are **two different backup layers** in this repository:

### 1) Local user-controlled backups
The app can ask the user to choose a folder through the Files picker and then write/read backup files there.

Use this when you want:
- manual restore
- offline backup portability
- local export/import behavior

### 2) Remote cloud backups
When backend support is enabled, the app can reconcile local state with remote backup metadata.

High level flow:
1. App calculates a local backup hash
2. App asks backend whether it should upload, download, noop, or resolve a conflict
3. Backup payloads are stored remotely
4. The app can restore a remote backup when appropriate

This remote flow is tied to an install identifier and is also used to decide whether the backend already has enough context for server-side coach requests.

## AI Coach flow

The coach feature is intentionally layered so it degrades gracefully.

### When backend is available
- the app builds a compact coach context from local data
- the client syncs or references snapshot state
- the Worker resolves context
- Workers AI generates profile insights and chat responses
- async operations can run through Cloudflare Workflows
- the app polls job state and can resume pending jobs

### When backend is unavailable
The app falls back to local heuristics for profile insights, so the product still remains functional instead of fully breaking.

## Backend setup

The backend lives in:

```text
backend/coach-worker
```

### Requirements
- Node.js 20+
- npm
- Cloudflare account with Workers enabled
- Wrangler CLI access

### Install dependencies
```bash
cd backend/coach-worker
npm install
```

### Local development
Create `.dev.vars` in `backend/coach-worker`:

```env
COACH_INTERNAL_TOKEN=replace-with-internal-token
AI_MODEL=@cf/mistralai/mistral-small-3.1-24b-instruct
COACH_PROMPT_VERSION=2026-03-25.v1
```

Then run:

```bash
npm run dev
```

### Checks
```bash
npm run typecheck
npm test
```

## Backend routes

Current backend routes include:

- `GET /health`
- `POST /v1/backup/reconcile`
- `PUT /v1/backup`
- `GET /v1/backup/download`
- `PATCH /v1/coach/preferences`
- `PUT /v1/coach/snapshot`
- `DELETE /v1/coach/state`
- `POST /v1/coach/profile-insights`
- `POST /v1/coach/chat`
- `POST /v2/coach/chat-jobs`
- `GET /v2/coach/chat-jobs/:jobID?installID=...`
- `POST /v2/coach/workout-summary-jobs`
- `GET /v2/coach/workout-summary-jobs/:jobID?installID=...`

All protected routes require:

```http
Authorization: Bearer <COACH_INTERNAL_TOKEN>
```

## Cloudflare bindings and services

The Worker expects these runtime integrations:

### Bindings
- `AI`
- `COACH_STATE_KV`
- `BACKUPS_R2`
- `APP_META_DB`
- `COACH_CHAT_WORKFLOW`
- `WORKOUT_SUMMARY_WORKFLOW`

### Vars / secrets
- `COACH_INTERNAL_TOKEN`
- `AI_MODEL`
- `COACH_PROMPT_VERSION`

### Current deployment shape
`wrangler.jsonc` is set up to use:

- Workers AI binding
- a KV namespace for coach state
- an R2 bucket for user backups
- a D1 database for metadata and migrations
- two workflows:
  - `coach-chat-job`
  - `workout-summary-job`

## Deploying the backend

From `backend/coach-worker`:

```bash
npm run deploy
```

This applies D1 migrations first and then deploys the Worker.

## GitHub Actions / CI

The repo includes a workflow at:

```text
.github/workflows/ios-build.yml
```

It performs two useful checks on hosted macOS runners:

1. **Build for iOS Simulator**
2. **Build unsigned iPhone artifact (`.ipa`)**

This is especially helpful when developing from Windows, because it verifies that the Xcode project still compiles even if the final device signing happens elsewhere.

## Development workflow

### Typical iOS-only changes
- edit SwiftUI views, models, or stores
- run locally in Xcode
- use the GitHub Action to verify simulator and unsigned device builds

### Typical backend-only changes
- edit Worker code in `backend/coach-worker`
- run `npm run typecheck`
- run `npm test`
- test with `wrangler dev`
- deploy with `npm run deploy`

### Full-stack changes
If you touch both the client and Worker:
- keep request/response contracts aligned
- verify build-time config values in the app
- verify Worker secrets/bindings in Cloudflare
- test fallback behavior when remote coach is disabled

## Notes and current constraints

- The app is **local-first** for core workout tracking, but AI and cloud sync require backend configuration.
- Real device installation still requires Apple signing/provisioning assets.
- The GitHub Action artifact for `iphoneos` is **unsigned** and not directly installable on a standard iPhone.
- Remote coach is intentionally gated behind runtime configuration and bearer auth.
- Do not commit production secrets, internal tokens, or personal backend URLs.

## Why this repository is structured this way

This repo keeps the product in one place:

- the iOS app evolves with real workout UX, local persistence, and fallback logic
- the Worker backend evolves with AI orchestration, remote context, and async jobs

That makes it practical to ship and debug end-to-end product behavior without splitting context across multiple repositories.

