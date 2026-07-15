import io

import pytest
from django.core.files.base import ContentFile
from django.core.management import call_command
from django.test import override_settings
from django.utils import timezone

from foods.models import FoodItem
from foods.serializers import FoodItemSerializer


def _create_item(external_id: str) -> FoodItem:
    return FoodItem.objects.create(
        source=FoodItem.SOURCE_OPEN_FOOD_FACTS,
        external_id=external_id,
        barcode=external_id,
        name="Repair Test Bar",
        brands="Test Brand",
        image_url="https://images.example.org/original.jpg",
        raw_source_json={"product": {}},
    )


def _mark_image_ok(item: FoodItem, *, write_file: bool) -> None:
    if write_file:
        item.image.save("front.jpg", ContentFile(b"jpegbytes"), save=False)
    else:
        # A DB row that references a file which was never persisted — the
        # exact state left behind when media was written before the volume
        # existed (or the volume was lost).
        item.image = f"foods/{item.barcode}/front.jpg"
    item.image_status = FoodItem.IMAGE_STATUS_OK
    item.image_downloaded_at = timezone.now()
    item.image_signature = "front_en.1"
    item.save()


@pytest.mark.django_db
def test_missing_file_row_is_reset_and_serializer_falls_back(tmp_path) -> None:
    with override_settings(MEDIA_ROOT=tmp_path):
        item = _create_item("repair-missing-001")
        _mark_image_ok(item, write_file=False)

        call_command("repair_food_images", stdout=io.StringIO())

        item.refresh_from_db()
        assert item.image_status == FoodItem.IMAGE_STATUS_NONE
        assert not item.image
        assert item.image_downloaded_at is None
        assert item.image_signature is None
        assert (
            FoodItemSerializer(item).data["image_url"]
            == "https://images.example.org/original.jpg"
        )


@pytest.mark.django_db
def test_intact_file_row_is_untouched(tmp_path) -> None:
    with override_settings(MEDIA_ROOT=tmp_path):
        item = _create_item("repair-intact-001")
        _mark_image_ok(item, write_file=True)

        call_command("repair_food_images", stdout=io.StringIO())

        item.refresh_from_db()
        assert item.image_status == FoodItem.IMAGE_STATUS_OK
        assert item.image
        assert item.image_signature == "front_en.1"


@pytest.mark.django_db
def test_dry_run_reports_but_does_not_change(tmp_path) -> None:
    with override_settings(MEDIA_ROOT=tmp_path):
        item = _create_item("repair-dry-001")
        _mark_image_ok(item, write_file=False)

        out = io.StringIO()
        call_command("repair_food_images", "--dry-run", stdout=out)

        item.refresh_from_db()
        assert item.image_status == FoodItem.IMAGE_STATUS_OK
        assert "would reset 1" in out.getvalue()
