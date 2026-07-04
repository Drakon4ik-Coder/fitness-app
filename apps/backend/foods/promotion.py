"""Convergence promotion (KAN-32): user nutrition edits become shared truth
when enough independent users propose matching values.

This deliberately replaces a searcher-vote model: independently typing the
same numbers off the same physical label is far stronger evidence than
agree-taps from users who don't have the package in hand. Plausibility gates
keep a coordinated-but-wrong cluster from landing junk.
"""

from __future__ import annotations

from decimal import Decimal
from statistics import median

from django.db import transaction
from django.utils import timezone

from foods.models import NUTRITION_FIELDS, FoodEditProposal, FoodItem

# Distinct users whose edits must agree before values propagate to everyone.
MIN_INDEPENDENT_EDITORS = 3

# Convergence band around the median: relative, with an absolute floor so
# tiny values (0.3 g of salt) aren't held to sub-decigram agreement.
RELATIVE_TOLERANCE = 0.05
ABSOLUTE_TOLERANCE = 0.5

# Promoted macros must roughly explain the promoted kcal (Atwater 4/4/9).
# Lenient on purpose: real labels legally round and deviate ~10-15%.
ATWATER_GATE = 0.30

# Physical per-100g ceilings, mirroring the /foods/custom validation.
_FIELD_BOUNDS = {
    field: 900.0 if field == "kcal_100g" else 100.0 for field in NUTRITION_FIELDS
}

# nutriments_json keys kept in sync with the promoted columns, so day totals
# (computed from the blob) agree with the card values (from the columns).
_OFF_KEYS = {
    "kcal_100g": "energy-kcal",
    "protein_g_100g": "proteins",
    "carbs_g_100g": "carbohydrates",
    "fat_g_100g": "fat",
    "sugars_g_100g": "sugars",
    "fiber_g_100g": "fiber",
    "salt_g_100g": "salt",
}


def _latest_proposal_per_user(food: FoodItem) -> list[FoodEditProposal]:
    latest: dict[int, FoodEditProposal] = {}
    pending = FoodEditProposal.objects.filter(
        food_item=food, status=FoodEditProposal.STATUS_PENDING
    ).order_by("id")
    for proposal in pending:
        # Later rows win: a user's newest correction supersedes their earlier
        # ones, so quorum counts users, not saves.
        latest[proposal.user_id] = proposal
    return list(latest.values())


def promote_pending_edits(food: FoodItem) -> bool:
    """Promotes the pending edits on [food] when they converge; returns
    whether a promotion happened. Safe to call opportunistically — it is a
    no-op below quorum."""
    proposals = _latest_proposal_per_user(food)
    if len(proposals) < MIN_INDEPENDENT_EDITORS:
        return False

    promoted: dict[str, float] = {}
    for field in NUTRITION_FIELDS:
        values = [v for p in proposals if (v := p.new_values.get(field)) is not None]
        if len(values) < 2:
            # A single voice never changes shared truth for a field.
            continue
        mid = float(median(values))
        allowed = max(RELATIVE_TOLERANCE * abs(mid), ABSOLUTE_TOLERANCE)
        if any(abs(v - mid) > allowed for v in values):
            # Editors disagree on this field — the item is disputed, and a
            # disputed item is not promoted at all.
            return False
        if len(values) >= MIN_INDEPENDENT_EDITORS:
            promoted[field] = round(mid, 2)

    if "kcal_100g" not in promoted:
        return False
    for field, value in promoted.items():
        if value < 0 or value > _FIELD_BOUNDS[field]:
            return False

    def effective(field: str) -> float | None:
        if field in promoted:
            return promoted[field]
        current = getattr(food, field)
        return None if current is None else float(current)

    kcal = promoted["kcal_100g"]
    protein = effective("protein_g_100g")
    carbs = effective("carbs_g_100g")
    fat = effective("fat_g_100g")
    if protein is not None and carbs is not None and fat is not None:
        expected = 4 * protein + 4 * carbs + 9 * fat
        if abs(expected - kcal) / max(kcal, 1.0) > ATWATER_GATE:
            return False

    with transaction.atomic():
        for field, value in promoted.items():
            setattr(food, field, Decimal(str(value)))
        nutriments = dict(food.nutriments_json or {})
        for field, value in promoted.items():
            off_key = _OFF_KEYS[field]
            nutriments[f"{off_key}_100g"] = value
            if field != "kcal_100g":
                nutriments[f"{off_key}_unit"] = "g"
        food.nutriments_json = nutriments
        food.community_verified_at = timezone.now()
        # The hash tracked the OFF-derived content; promoted values are a new
        # lineage, so clear it — clients' check calls report not-up-to-date
        # and their re-ingest pulls the promoted item back (nutrition fields
        # are frozen against the re-ingest itself).
        food.content_hash = None
        food.save()
        FoodEditProposal.objects.filter(
            food_item=food, status=FoodEditProposal.STATUS_PENDING
        ).update(status=FoodEditProposal.STATUS_PROMOTED)
    return True


def sweep() -> int:
    """Attempts promotion for every food with pending proposals; returns how
    many were promoted. For the management command / a future cron."""
    food_ids = (
        FoodEditProposal.objects.filter(status=FoodEditProposal.STATUS_PENDING)
        .values_list("food_item_id", flat=True)
        .distinct()
    )
    count = 0
    for food in FoodItem.objects.filter(id__in=list(food_ids)):
        if promote_pending_edits(food):
            count += 1
    return count
