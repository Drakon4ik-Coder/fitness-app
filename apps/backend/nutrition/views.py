from datetime import date, datetime, timedelta, tzinfo
from decimal import Decimal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.db.models import Q
from django.shortcuts import get_object_or_404
from django.utils import timezone
from drf_spectacular.types import OpenApiTypes
from drf_spectacular.utils import OpenApiParameter, OpenApiResponse, extend_schema
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from nutrition.models import MealEntry
from nutrition.serializers import (
    MealEntryCreateSerializer,
    MealEntrySerializer,
    MealEntryUpdateSerializer,
    MealTimesSerializer,
    NutritionDaySerializer,
    SyncPageSerializer,
)
from nutrients.catalog import NUTRIENT_CATALOG
from nutrition.utils import (
    calculate_macros,
    calculate_nutrients,
    serialize_decimal,
    summarize_meal_time,
)

_NUTRIENT_SPEC_BY_KEY = {spec.key: spec for spec in NUTRIENT_CATALOG}

User = get_user_model()

_UTC = ZoneInfo("UTC")


def _user_zone(user: object) -> tzinfo:
    """The user's IANA timezone, or UTC if unset/invalid.

    Meal entries are stored as true UTC instants; both the day grouping and the
    meal-time stats convert them back to this zone to recover the wall-clock time
    the user actually experienced.
    """
    name = getattr(user, "timezone", None) or "UTC"
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return _UTC


def _clamp_mutation_time(client_time: datetime | None) -> datetime:
    """The LWW mutation timestamp to store for an accepted write.

    Client-supplied times let a replayed offline edit keep its true moment (so
    a newer edit from another device still beats it), but a fast client clock
    must not mint timestamps that would out-rank future server-side writes —
    clamp to server "now".
    """
    now = timezone.now()
    if client_time is None:
        return now
    return min(client_time, now)


class MealEntryCreateView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(
        request=MealEntryCreateSerializer,
        responses={
            200: MealEntrySerializer,
            201: MealEntrySerializer,
            400: OpenApiResponse(description="Invalid payload"),
            401: OpenApiResponse(description="Unauthorized"),
        },
    )
    def post(self, request: Request) -> Response:
        serializer = MealEntryCreateSerializer(
            data=request.data, context={"request": request}
        )
        serializer.is_valid(raise_exception=True)
        # Idempotent replay (KAN-28): an offline create whose first ack was lost
        # arrives again with the same client uuid — hand back the existing row
        # (even a since-deleted one; the tombstone reaches the client via delta
        # sync) instead of duplicating the meal.
        client_uuid = serializer.validated_data.get("client_uuid")
        if client_uuid is not None:
            assert isinstance(request.user, User)
            existing = MealEntry.objects.filter(
                user=request.user, client_uuid=client_uuid
            ).first()
            if existing is not None:
                output = MealEntrySerializer(existing, context={"request": request})
                return Response(output.data, status=status.HTTP_200_OK)
        entry = serializer.save()
        # A new entry can shift the learned meal times; drop the cached value so
        # the next fetch recomputes (esp. important while a new user's habits form).
        cache.delete(meal_times_cache_key(entry.user_id, str(_user_zone(request.user))))
        output = MealEntrySerializer(entry, context={"request": request})
        return Response(output.data, status=status.HTTP_201_CREATED)


class MealEntryDetailView(APIView):
    """Edit/delete one entry, addressed by server pk or client uuid.

    The uuid route exists for offline replays (KAN-28): an entry created
    offline is edited before the server ever assigned it a pk, so queued ops
    can only reference the client uuid.
    """

    permission_classes = [IsAuthenticated]

    def _get_entry(
        self, request: Request, pk: int | None, client_uuid: UUID | None
    ) -> MealEntry:
        if pk is not None:
            return get_object_or_404(MealEntry, pk=pk, user=request.user)
        return get_object_or_404(MealEntry, client_uuid=client_uuid, user=request.user)

    @extend_schema(
        request=MealEntryUpdateSerializer,
        responses={
            200: MealEntrySerializer,
            400: OpenApiResponse(description="Invalid payload"),
            401: OpenApiResponse(description="Unauthorized"),
            404: OpenApiResponse(description="Entry not found"),
        },
    )
    def patch(
        self, request: Request, pk: int | None = None, client_uuid: UUID | None = None
    ) -> Response:
        entry = self._get_entry(request, pk, client_uuid)
        if entry.deleted_at is not None:
            # Delete wins over a late edit: the entry is gone everywhere else,
            # so resurrecting it here would undo another device's delete.
            return Response(
                {"detail": "Entry deleted."}, status=status.HTTP_404_NOT_FOUND
            )
        previous_meal_type = entry.meal_type
        serializer = MealEntryUpdateSerializer(entry, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        # LWW (KAN-28): a replayed offline edit loses to any change the entry
        # received after the edit was made — respond with the current state so
        # the losing client converges instead of erroring.
        client_updated_at = serializer.validated_data.pop("client_updated_at", None)
        if client_updated_at is not None and entry.updated_at > client_updated_at:
            return Response(
                MealEntrySerializer(entry, context={"request": request}).data
            )
        entry = serializer.save(updated_at=_clamp_mutation_time(client_updated_at))
        # Moving an entry to a different meal changes the learned meal-time
        # histogram, so drop the cached stats to force a recompute (mirrors the
        # create path). Best-effort; only when the meal type actually changed.
        if entry.meal_type != previous_meal_type:
            cache.delete(
                meal_times_cache_key(entry.user_id, str(_user_zone(request.user)))
            )
        return Response(MealEntrySerializer(entry, context={"request": request}).data)

    @extend_schema(
        parameters=[
            OpenApiParameter(
                name="client_updated_at",
                type=OpenApiTypes.DATETIME,
                required=False,
                description=(
                    "LWW mutation time of a replayed offline delete; the delete "
                    "is dropped when the entry changed more recently."
                ),
            )
        ],
        responses={
            204: OpenApiResponse(description="Entry deleted (or delete superseded)"),
            400: OpenApiResponse(description="Invalid client_updated_at"),
            401: OpenApiResponse(description="Unauthorized"),
            404: OpenApiResponse(description="Entry not found"),
        },
    )
    def delete(
        self, request: Request, pk: int | None = None, client_uuid: UUID | None = None
    ) -> Response:
        entry = self._get_entry(request, pk, client_uuid)
        if entry.deleted_at is not None:
            # Already tombstoned (e.g. the same delete replayed twice) — done.
            return Response(status=status.HTTP_204_NO_CONTENT)
        raw_client_time = request.query_params.get("client_updated_at")
        client_updated_at = None
        if raw_client_time:
            try:
                client_updated_at = datetime.fromisoformat(raw_client_time)
            except ValueError:
                return Response(
                    {"detail": "Invalid client_updated_at."},
                    status=status.HTTP_400_BAD_REQUEST,
                )
            if timezone.is_naive(client_updated_at):
                client_updated_at = timezone.make_aware(client_updated_at, _UTC)
            if entry.updated_at > client_updated_at:
                # The entry was edited after this offline delete was queued —
                # the newer edit wins and the delete is dropped. 204 so the
                # replaying client clears the op; delta sync restores the row.
                return Response(status=status.HTTP_204_NO_CONTENT)
        # Soft delete: the tombstone must outlive the row so other devices
        # learn about the delete on their next delta pull.
        entry.deleted_at = timezone.now()
        entry.updated_at = _clamp_mutation_time(client_updated_at)
        entry.save(update_fields=["deleted_at", "updated_at", "synced_at"])
        return Response(status=status.HTTP_204_NO_CONTENT)


class NutritionDayView(APIView):
    permission_classes = [IsAuthenticated]

    @extend_schema(
        parameters=[
            OpenApiParameter(
                name="date",
                type=OpenApiTypes.DATE,
                required=False,
                description="Date in YYYY-MM-DD format (defaults to today).",
            )
        ],
        responses={
            200: NutritionDaySerializer,
            400: OpenApiResponse(description="Invalid date"),
            401: OpenApiResponse(description="Unauthorized"),
        },
    )
    def get(self, request: Request) -> Response:
        assert isinstance(request.user, User)
        user = request.user
        zone = _user_zone(user)

        date_raw = request.query_params.get("date")
        if date_raw:
            try:
                target_date = date.fromisoformat(date_raw)
            except ValueError:
                return Response(
                    {"detail": "Invalid date format. Use YYYY-MM-DD."},
                    status=status.HTTP_400_BAD_REQUEST,
                )
        else:
            target_date = timezone.localdate(timezone=zone)

        # consumed_at is true UTC; the __date lookup uses the active timezone, so
        # grouping happens on the user's local calendar day, not UTC's.
        with timezone.override(zone):
            entries = list(
                MealEntry.objects.filter(
                    user=user,
                    consumed_at__date=target_date,
                    # Tombstoned entries stay in the table for delta sync but
                    # are gone as far as the day log is concerned.
                    deleted_at__isnull=True,
                )
                .select_related("food_item")
                .order_by("consumed_at")
            )

        meals: dict[str, list[MealEntry]] = {
            MealEntry.MEAL_BREAKFAST: [],
            MealEntry.MEAL_LUNCH: [],
            MealEntry.MEAL_DINNER: [],
            MealEntry.MEAL_SNACKS: [],
        }
        totals = {
            "kcal": Decimal("0"),
            "protein_g": Decimal("0"),
            "carbs_g": Decimal("0"),
            "fat_g": Decimal("0"),
        }
        # Generic per-nutrient accumulator, keyed by catalog key. Only nutrients
        # that at least one food actually carried appear (a floor, not an
        # estimate) — absent keys read as "no data" on the client. We also count
        # how many of the day's foods reported each nutrient so the client can
        # flag a total as "incomplete" when some foods lack it (macros/core).
        nutrient_sums: dict[str, Decimal] = {}
        nutrient_reported: dict[str, int] = {}
        entry_count = len(entries)

        for entry in entries:
            meals[entry.meal_type].append(entry)
            macros = calculate_macros(entry.food_item, entry.quantity_g)
            for key, value in macros.items():
                totals[key] += value
            for key, value in calculate_nutrients(
                entry.food_item, entry.quantity_g
            ).items():
                nutrient_sums[key] = nutrient_sums.get(key, Decimal("0")) + value
                nutrient_reported[key] = nutrient_reported.get(key, 0) + 1

        nutrients = {
            key: {
                "amount": serialize_decimal(value),
                "unit": _NUTRIENT_SPEC_BY_KEY[key].unit,
                "group": _NUTRIENT_SPEC_BY_KEY[key].group,
                # How many foods reported it vs how many were logged, so the
                # client can show "incomplete" for tracked nutrients.
                "reported": nutrient_reported.get(key, 0),
                "total": entry_count,
            }
            for key, value in nutrient_sums.items()
        }

        response_data = {
            "date": target_date,
            "totals": {key: serialize_decimal(value) for key, value in totals.items()},
            "nutrients": nutrients,
            "meals": {
                "breakfast": meals[MealEntry.MEAL_BREAKFAST],
                "lunch": meals[MealEntry.MEAL_LUNCH],
                "dinner": meals[MealEntry.MEAL_DINNER],
                "snacks": meals[MealEntry.MEAL_SNACKS],
            },
        }
        serializer = NutritionDaySerializer(response_data, context={"request": request})
        return Response(serializer.data)


def meal_times_cache_key(user_id: int, tz_name: str) -> str:
    # The tz is part of the key: change zones and the learned hours change too, so
    # a new key naturally supersedes the old (which simply ages out via TTL).
    return f"nutrition:meal_times:{user_id}:{tz_name}"


# Typical meal times drift over days, not seconds, and a stale value only nudges
# a default dropdown — so a day-long TTL is the real freshness guarantee. We also
# bust the key on entry create (best-effort: global with a shared cache backend
# like Redis, per-process otherwise), so a new user's habits surface promptly.
MEAL_TIMES_CACHE_TTL = 60 * 60 * 24

# Only recent habits matter; older entries shouldn't anchor a window the user
# has since drifted away from.
MEAL_TIMES_LOOKBACK_DAYS = 90


def compute_meal_times(user_id: int, zone: tzinfo) -> dict[str, dict[str, float | int]]:
    since = timezone.now() - timedelta(days=MEAL_TIMES_LOOKBACK_DAYS)
    rows = MealEntry.objects.filter(
        user_id=user_id,
        consumed_at__gte=since,
        deleted_at__isnull=True,
        meal_type__in=[
            MealEntry.MEAL_BREAKFAST,
            MealEntry.MEAL_LUNCH,
            MealEntry.MEAL_DINNER,
        ],
    ).values_list("meal_type", "consumed_at")

    hours_by_meal: dict[str, list[float]] = {}
    for meal_type, consumed_at in rows:
        # consumed_at is a true UTC instant; convert to the user's zone to recover
        # the wall-clock hour they experienced — the "when do I eat" signal.
        local = consumed_at.astimezone(zone)
        hours_by_meal.setdefault(meal_type, []).append(local.hour + local.minute / 60.0)

    meal_times: dict[str, dict[str, float | int]] = {}
    for meal_type, hours in hours_by_meal.items():
        summary = summarize_meal_time(hours)
        if summary is not None:
            meal_times[meal_type] = summary
    return meal_times


# One page of the delta feed. Small enough for a snappy mobile pull, big enough
# that a normal day's logging fits in one page.
SYNC_PAGE_LIMIT = 200


def _encode_sync_cursor(synced_at: datetime, pk: int) -> str:
    return f"{synced_at.isoformat()}|{pk}"


def _decode_sync_cursor(raw: str) -> tuple[datetime, int]:
    time_part, _, id_part = raw.partition("|")
    synced_at = datetime.fromisoformat(time_part)
    if timezone.is_naive(synced_at):
        synced_at = timezone.make_aware(synced_at, _UTC)
    return synced_at, int(id_part)


class MealEntrySyncView(APIView):
    """Delta feed for the client's entry-level cache (KAN-28 Phase 2).

    Returns every entry created/updated/deleted since the given cursor,
    tombstones included, so an already-cached day refreshes without a full
    `/day` re-fetch and other devices' changes propagate.

    The cursor is `synced_at|id` — synced_at is server-monotonic (unlike
    updated_at, which replayed offline writes can set in the past) and the id
    breaks ties when several rows share one timestamp (bulk writes). Without
    `since`, no entries are returned, just a fresh cursor: the client
    bootstraps its cursor *before* seeding days via full fetches, so anything
    changing in between is re-delivered (merging is idempotent).
    """

    permission_classes = [IsAuthenticated]

    @extend_schema(
        parameters=[
            OpenApiParameter(
                name="since",
                type=OpenApiTypes.STR,
                required=False,
                description=(
                    "Opaque cursor from a previous response; omit to bootstrap."
                ),
            ),
            OpenApiParameter(
                name="limit",
                type=OpenApiTypes.INT,
                required=False,
                description=f"Page size (default and max {SYNC_PAGE_LIMIT}).",
            ),
        ],
        responses={
            200: SyncPageSerializer,
            400: OpenApiResponse(description="Invalid cursor"),
            401: OpenApiResponse(description="Unauthorized"),
        },
    )
    def get(self, request: Request) -> Response:
        assert isinstance(request.user, User)
        raw_since = request.query_params.get("since")
        if not raw_since:
            payload = {
                "entries": [],
                "next_cursor": _encode_sync_cursor(timezone.now(), 0),
                "has_more": False,
            }
            return Response(SyncPageSerializer(payload).data)

        try:
            since_time, since_id = _decode_sync_cursor(raw_since)
        except ValueError:
            return Response(
                {"detail": "Invalid cursor."}, status=status.HTTP_400_BAD_REQUEST
            )
        try:
            limit = int(request.query_params.get("limit", SYNC_PAGE_LIMIT))
        except ValueError:
            limit = SYNC_PAGE_LIMIT
        limit = max(1, min(limit, SYNC_PAGE_LIMIT))

        rows = list(
            MealEntry.objects.filter(user=request.user)
            .filter(
                Q(synced_at__gt=since_time) | Q(synced_at=since_time, id__gt=since_id)
            )
            .select_related("food_item")
            .order_by("synced_at", "id")[: limit + 1]
        )
        has_more = len(rows) > limit
        rows = rows[:limit]
        next_cursor = (
            _encode_sync_cursor(rows[-1].synced_at, rows[-1].pk) if rows else raw_since
        )
        payload = {
            "entries": rows,
            "next_cursor": next_cursor,
            "has_more": has_more,
        }
        return Response(SyncPageSerializer(payload, context={"request": request}).data)


class MealTimesView(APIView):
    """Per-user typical meal times, learned from recent logging history.

    Powers the app's smart meal-type guess: the client centers each meal's
    window on the user's own median time, falling back to population defaults
    for any meal it hasn't seen enough of. The result is cached per user since
    it changes only slowly (see MEAL_TIMES_CACHE_TTL).
    """

    permission_classes = [IsAuthenticated]

    @extend_schema(
        responses={
            200: MealTimesSerializer,
            401: OpenApiResponse(description="Unauthorized"),
        },
    )
    def get(self, request: Request) -> Response:
        assert isinstance(request.user, User)
        user = request.user
        zone = _user_zone(user)
        key = meal_times_cache_key(user.pk, str(zone))
        meal_times = cache.get(key)
        if meal_times is None:
            meal_times = compute_meal_times(user.pk, zone)
            cache.set(key, meal_times, MEAL_TIMES_CACHE_TTL)
        serializer = MealTimesSerializer({"meal_times": meal_times})
        return Response(serializer.data)
