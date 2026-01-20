# Release Process

## Versioning
Use Semantic Versioning (SemVer): `MAJOR.MINOR.PATCH` and tag releases as `vX.Y.Z`.

## Preconditions
- `main` is green in CI (Backend CI, Mobile CI, Meta CI).
- `contracts/openapi.yaml` is up to date when API changes are included.
- CHANGELOG entry for the release is prepared.

## Steps
1. Update versions where applicable:
   - `apps/mobile/pubspec.yaml`
   - `apps/backend/pyproject.toml`
2. Update `CHANGELOG.md` (move items from Unreleased into the new version section).
3. Create a release commit and push it to `main`.
4. Tag and push:
   - `git tag vX.Y.Z`
   - `git push origin vX.Y.Z`
5. Create a GitHub Release using the notes template below.

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
