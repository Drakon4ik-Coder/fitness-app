# Play Store Publication Roadmap — Symbio

Status of the app as of 2026-07-06, followed by a phased plan to get
`uk.drakon4ik.symbio` live on Google Play.

## Where we stand

**Already in good shape**
- Signed release builds: keystore-based signing wired in `app/build.gradle.kts`,
  `mobile-release.yml` builds a signed APK per push to `main` and publishes it
  as a GitHub Release. `print-signing-sha.yml` exists for OAuth fingerprints.
- Target/min SDK: merged release manifest targets API 36 (Android 16),
  minSdk 24 — comfortably above Google's 2026 target-API requirement.
- Unique application id (`uk.drakon4ik.symbio`), launcher icons + adaptive
  icon + Android 12 splash generated, app label "Symbio".
- HTTPS-only in release (cleartext allowed only in the debug manifest's
  network security config).
- Production backend at `symbio.drakon4ik.uk` (self-hosted docker-compose,
  Postgres 16), staging on Render. Rate limiting, JWT auth, email
  verification, password reset all live. Contract-first API with CI.
- CI for both apps; full mobile test suite green.

**Gaps that block or endanger a Play submission**

| # | Gap | Why it matters |
|---|-----|----------------|
| 1 | No account-deletion endpoint or in-app flow (`accounts/urls.py` has register/token/me/verify/reset only) | Play *requires* apps that offer account creation to provide in-app account deletion **and** a web link for deletion requests, declared in the Data safety form. Hard blocker. |
| 2 | No privacy policy (nothing hosted, nothing in-app) | Required for every app; doubly so because Symbio collects email + health/nutrition data. Hard blocker. |
| 3 | Health-data handling undeclared | Nutrition tracking puts the app under Play's Health apps policy: Health apps declaration in Play Console + privacy policy covering health data. |
| 4 | CI builds an APK, not an AAB | Play only accepts Android App Bundles for new apps, with Play App Signing (Google holds the distribution key; our keystore becomes the *upload* key). |
| 5 | Google Sign-In will break on Play-delivered builds | Play App Signing re-signs the app with Google's key, so the Android OAuth client also needs the **Play app-signing certificate SHA-1** (from Play Console → App integrity), not just our upload key's SHA-1. |
| 6 | No crash reporting in the mobile app (backend Sentry is configurable but DSN unset) | Not a policy blocker, but flying blind in production; pre-launch report issues will be hard to triage. |
| 7 | `INTERNET` permission absent from `src/main/AndroidManifest.xml` | Currently inherited from a plugin's manifest merge — works today, but fragile: dropping/replacing that plugin silently kills networking in release builds. Declare it explicitly. |
| 8 | Open Food Facts attribution only in README | ODbL requires attribution where the data is used. Add an in-app About/Licenses screen ("Powered by Open Food Facts", ODbL link, plus Flutter `LicensePage` and Apache NOTICE). |
| 9 | No Play developer account yet (assumed) | Personal accounts must run a **closed test with ≥12 testers opted in for 14 consecutive days** before they can apply for production access. This is the schedule-critical path — start it early. |
| 10 | Backend has no visible backup/monitoring story | Postgres lives in a single docker volume; no backups, no uptime alerting, Sentry DSN unset. Real users = real data-loss and downtime risk. |

## Roadmap

### Phase 0 — Unblock the clock (do first, ~1 day)
The 14-day closed test is the longest fixed delay; everything here starts it sooner.
- [ ] Register the Google Play developer account ($25 one-time). Decide
  personal vs organization (organization needs a D-U-N-S number but avoids
  some personal-account verification friction and looks better on the listing).
- [ ] Complete identity verification (can take days — don't leave it late).
- [ ] Create the app entry ("Symbio", free, Health & Fitness) and enroll in
  Play App Signing, using the existing keystore as the upload key.
- [ ] Recruit 12–15 testers (friends/colleagues with Google accounts) now.

### Phase 1 — Policy compliance features (~1 week, app + backend work)
- [x] **Account deletion** (KAN-42):
  - Backend: `DELETE /api/v1/auth/me` (re-auth: password, or a fresh Google
    ID token for OAuth-only accounts) that deletes the user and cascades
    meals/preferences/custom foods; plus a web page at
    `symbio.drakon4ik.uk/delete-account` where a logged-out user requests an
    emailed, single-use confirmation link (Play requires a web path too).
  - Mobile: "Delete account" in Settings → Profile with confirm dialog,
    then local wipe (secure storage + both SQLite DBs) and sign-out.
- [ ] **Privacy policy**: write and host at `symbio.drakon4ik.uk/privacy`
  (static Django template is fine). Must cover: email/account data, health &
  nutrition data, device timezone, Google Sign-In, camera/barcode usage
  (on-device only), crash logs/diagnostics (Sentry), retention, deletion,
  contact address. Link it in-app
  (Settings → About) and later in the store listing.
- [ ] **About/Licenses screen** in Settings: app version, "Powered by Open
  Food Facts" (ODbL) attribution, link to privacy policy, Flutter
  `showLicensePage`, Apache-2.0/NOTICE.
- [ ] Add `<uses-permission android:name="android.permission.INTERNET"/>` to
  the main manifest explicitly.
- [x] **Crash reporting** (KAN-44): `sentry_flutter` wired to
  `appErrorLogger`; one org, two projects (backend + mobile), staging/prod
  split by the Sentry `environment` tag, `local` never reports. Code-side
  done; still manual: create the Sentry projects and set `SENTRY_DSN` (+
  `SENTRY_ENVIRONMENT=prod`) on the prod server `.env`, the DSN on Render,
  and the `SENTRY_MOBILE_DSN` GitHub secret. Mention crash collection in the
  privacy policy + Data safety form (folded into those items below/Phase 3).

### Phase 2 — Release engineering (~2–3 days)
- [ ] Switch `mobile-release.yml` to also build `flutter build appbundle
  --release` and upload the `.aab` artifact. Keep the APK for GitHub Releases.
- [ ] Keep `--build-number=${{ github.run_number }}` as versionCode (monotonic ✅);
  bump `pubspec.yaml` to the version you want to launch as.
- [ ] Upload first AAB to the **Internal testing** track manually; verify
  install, login, scan, log, sync on a real device.
- [ ] Fix Google Sign-In for Play builds: copy the app-signing certificate
  SHA-1 from Play Console → Test and release → App integrity, add it as an
  Android OAuth client (same package id) in the Google Cloud project.
  Re-test sign-in with a build installed *from Play*, not sideloaded.
- [ ] Optional but recommended: automate uploads with Gradle Play Publisher
  or `r0adkll/upload-google-play` using a Play Console service account.

### Phase 3 — Store presence & declarations (~2–3 days, parallel with Phase 2)
- [ ] Store listing: short description (80 chars), full description, at least
  4 phone screenshots (1080×1920+; the dark Lumina UI screenshots well),
  512×512 icon, 1024×500 feature graphic.
- [ ] **Data safety form**. Declared collected data at minimum: email address
  (account), health info (nutrition logs), crash logs/diagnostics (if Sentry
  added). All encrypted in transit ✅; deletion mechanism ✅ (Phase 1). No ads,
  no data sold, no third-party sharing (OFF lookups send barcodes, not
  personal data — verify wording).
- [ ] **Health apps declaration** (required for Health & Fitness category).
- [ ] Content rating questionnaire (IARC) — expect Everyone.
- [ ] Target audience: 18+ (or 13+) — do *not* include children; that
  triggers Families policy. Ads declaration: none. App access: provide a
  working test account (login is email-verified — create reviewer
  credentials with verification pre-completed).
- [ ] Check "Symbio" name availability/trademark on Play; have a fallback
  display name ("Symbio — Nutrition Tracker" also helps search).

### Phase 4 — Closed testing, the mandatory 14 days
- [ ] Promote the build to **Closed testing**, opt in the 12+ testers, and
  keep them opted in for 14 consecutive days (personal-account requirement).
- [ ] Watch the **pre-launch report** (Play runs the app on real devices):
  fix crashes, ANRs, accessibility flags.
- [ ] Use the window to burn down real-usage bugs (offline sync across
  devices, OFF rate limiting under multiple users, email deliverability to
  Gmail/Outlook — check SPF/DKIM on the sending domain).
- [ ] Backend hardening during the window:
  - Nightly `pg_dump` off the host (even a cron to object storage/rclone).
  - Uptime monitoring on `/health/` (UptimeRobot/healthchecks.io).
  - Confirm `docker-compose.prod.yml` survives host reboot (restart policies ✅).

### Phase 5 — Production
- [ ] Apply for production access (answer Google's questions about testing
  learnings), submit for review.
- [ ] Staged rollout (start 20%), monitor Sentry + Play vitals, then 100%.
- [ ] Post-launch loop: `docs/RELEASE.md` process + closed track as beta
  channel for future releases.

## Critical path & rough timeline

```
Week 1: Phase 0 + Phase 1 (account deletion, privacy policy, attribution, Sentry)
Week 2: Phase 2 + 3 (AAB pipeline, sign-in fix, listing, declarations)
Weeks 3–4: Phase 4 closed test (fixed 14-day clock) + hardening
Week 5: production access review (Google review can take ~1 week) → launch
```

Realistic target: **live in ~5–6 weeks**, dominated by the 14-day closed test
and Google review times — which is why Phase 0 and tester recruitment happen
first.
