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

## Build releases (automatic — every push to `main`)

When Mobile CI goes green on `main`, `mobile-release.yml`:

1. builds a signed APK and AAB with `versionCode = GitHub run number`
   (monotonic, required by Play),
2. tags the commit `vX.Y.Z+<run number>` (version name from `pubspec.yaml`),
3. publishes a GitHub Release with auto-generated notes and the APK attached;
   the AAB is uploaded as a workflow artifact for the Play Store.

These are build releases: no manual steps, no version bump, no CHANGELOG
movement.

## Version releases (manual — user-facing milestones)

Bump `X.Y.Z` when shipping something worth signalling: a Play Store rollout,
a feature milestone, or an API change clients must care about.

1. Verify `main` is green in CI (Backend CI, Mobile CI, Meta CI).
2. Bump both version sources listed above; re-export the contract
   (`make backend-contract`).
3. Move CHANGELOG `Unreleased` items into a new `[X.Y.Z]` section.
4. Land it on `main` through the normal PR flow. The next `main` build tags
   `vX.Y.Z+<run number>` with the new version automatically — do not create
   a bare `vX.Y.Z` tag by hand.
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
