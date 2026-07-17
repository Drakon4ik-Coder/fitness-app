# Release Process

## Versioning

The app version is Semantic Versioning (SemVer) `MAJOR.MINOR.PATCH`, stored in
exactly two files that must move together:

- `apps/mobile/pubspec.yaml` — `version: X.Y.Z+1` (the `+1` build number is a
  placeholder; CI overrides it with the workflow run number).
- `apps/backend/pyproject.toml` — `[project] version`. The backend reads this
  at startup (`settings.APP_VERSION`), so the `/health/` payload and the
  OpenAPI `info.version` follow automatically. A bump therefore changes
  `contracts/openapi.yaml` — run `make backend-contract` in the same commit.

## Cutting a release (manual — Actions → Mobile Release)

Releases are dispatch-only: run the **Mobile Release** workflow on `main`
(it refuses other branches). Verify `main` is green (Backend CI, Mobile CI)
first — dispatch does not wait for CI. The workflow:

1. builds a signed APK and AAB with `versionCode = GitHub run number`
   (monotonic, required by Play),
2. tags the commit `vX.Y.Z+<run number>` (version name from `pubspec.yaml`),
3. publishes a GitHub Release with auto-generated notes and the APK attached;
   the AAB is uploaded as a workflow artifact for the Play Store.

Tester builds don't go through this — use `mobile-staging.yml` (Firebase App
Distribution). The backend has no release step at all: `deploy-server.yml`
deploys `main` to production automatically after every green Backend CI
push run.

## Version bumps (user-facing milestones)

Bump `X.Y.Z` when shipping something worth signalling: a Play Store rollout,
a feature milestone, or an API change clients must care about.

1. Bump both version sources listed above; re-export the contract
   (`make backend-contract`).
2. Move CHANGELOG `Unreleased` items into a new `[X.Y.Z]` section.
3. Land it on `main` through the normal PR flow.
4. Run the **Mobile Release** workflow — the tag becomes `vX.Y.Z+<run>` with
   the new version. Do not create a bare `vX.Y.Z` tag by hand.
5. Optionally edit that GitHub Release's generated notes into the template
   below.

## Release notes template

```
## Highlights
- ...

## Backend
- ...

## Mobile
- ...

## Infra/Docs
- ...

## Upgrading
- ...
```
