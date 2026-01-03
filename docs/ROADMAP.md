# Fitness App — Roadmap (v1)

## Phase 0 — Foundation (Week 1–2)
- Contracts:
  - Generate OpenAPI from backend and commit to contracts/openapi.yaml
  - CI check: regenerate schema and fail on diff
- Reproducible builds:
  - Commit backend poetry.lock and ensure CI uses it
- Core infra:
  - /health endpoint
  - JWT auth (register/login/refresh/me)
  - UserPreferences (units, goals, dietary prefs)

## Phase 1 — MVP Logging (Week 2–5)
Nutrition (v0):
- Barcode lookup using OFF product endpoint (hybrid cache)
- Meal logging: create meal + add food items + daily totals
- Nutrient registry:
  - user can enable/track custom nutrients (creatine, vit D, etc.)

Workouts (v0):
- Exercise list (base + user custom)
- Workout sessions + sets + history list

Analytics (v0):
- Weekly summaries:
  - calories/protein trend
  - workout frequency
- Basic caching/aggregation (nightly job or on-write updates)

Feedback (v0):
- Feature ideas + votes + comments

## Phase 2 — Recipes & Planning (Week 5–8)
Recipes (v0):
- Import a legally usable starter dataset (license-compliant)
- Browse/search recipes (local DB)
- Rate recipes

Meal planning (v0):
- Weekly meal plan creation
- “Suggest meals” v0:
  - rule-based scoring (expiry soon + ingredient match + goal fit)

## Phase 3 — Pantry/Fridge (Week 8–10)
Inventory (v0):
- Pantry/fridge items with quantity + expiry
- Prepared meals as batches (servings + expiry)
- Connect inventory to meal suggestions (reduce waste)

## Phase 4 — Community + Moderation (Week 10+)
- Moderated publishing for recipes/products/exercises:
  - private creation → submit → approve → public
- Reporting/flagging and admin review tools

## Phase 5 — Forum + Realtime Workouts (Later)
Forum:
- Categories + threads + posts + moderation integration

Training together:
- Group workout sessions
- v0 polling sync → v1 websockets (Channels)
- Anti-abuse + privacy controls

## Global readiness checklist (ongoing)
- Timezones + units support everywhere
- i18n-ready text + multi-language fields for catalog content (later)
- Attribution & license compliance for external datasets and images
