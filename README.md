# WorkoutApp iOS MVP

SwiftUI MVP for a personal workout app with:
- workout program builder
- searchable exercise catalog grouped by muscle groups
- active workout timer and set logging
- superset support
- workout history and per-exercise charts
- bilingual UI (English / Russian)

## Notes
- The repository was initially empty, so the Xcode project is generated manually.
- Build and deployment to a personal iPhone from Windows will still require access to Apple tooling at signing/build time.

## Windows Verification
- The repository now includes a GitHub Actions workflow at `.github/workflows/ios-build.yml`.
- From Windows, push the branch to GitHub and run the `iOS Build` workflow in the Actions tab to verify that the project compiles on a hosted macOS runner.
- The workflow builds an iOS Simulator app and uploads it as an artifact. This confirms compilation, but it is not installable on a physical iPhone.
- The same workflow also packages `WorkoutApp-unsigned.ipa` for `iphoneos` as an artifact. This file is useful for inspection or later signing, but it is not installable on a normal iPhone until it is signed with Apple provisioning assets.

## AI Coach Backend
- The Cloudflare Worker backend for AI Coach lives in `backend/coach-worker`.
- It exposes `GET /health`, `POST /v1/coach/profile-insights`, and `POST /v1/coach/chat`.
- Local setup, Cloudflare Git integration, and runtime secrets are documented in `backend/coach-worker/README.md`.
