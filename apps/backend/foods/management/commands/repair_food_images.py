from typing import Any

from django.core.management.base import BaseCommand, CommandParser

from foods.models import FoodItem


class Command(BaseCommand):
    help = (
        "Reset image bookkeeping on food items whose stored media file is "
        "missing (e.g. rows written before the media volume existed, or "
        "after a volume loss). Clearing image_status makes the serializer "
        "fall back to the original source image_url and lets clients "
        "re-upload, so affected foods heal on their next fetch."
    )

    def add_arguments(self, parser: CommandParser) -> None:
        parser.add_argument(
            "--dry-run",
            action="store_true",
            help="Only report rows that would be reset.",
        )

    def handle(self, *args: Any, **options: Any) -> None:
        dry_run: bool = options["dry_run"]
        candidates = (
            FoodItem.objects.filter(image_status=FoodItem.IMAGE_STATUS_OK)
            .exclude(image__isnull=True)
            .exclude(image="")
        )
        checked = 0
        broken = 0
        for item in candidates.iterator():
            checked += 1
            if item.image.storage.exists(item.image.name):
                continue
            broken += 1
            self.stdout.write(f"missing file: id={item.pk} {item.image.name}")
            if dry_run:
                continue
            # Signature must be cleared with the status: the upload view
            # short-circuits on a matching signature, and a stale one would
            # be misleading next to status "none".
            item.image = None
            item.image_status = FoodItem.IMAGE_STATUS_NONE
            item.image_downloaded_at = None
            item.image_signature = None
            item.save(
                update_fields=[
                    "image",
                    "image_status",
                    "image_downloaded_at",
                    "image_signature",
                ]
            )
        verb = "would reset" if dry_run else "reset"
        self.stdout.write(
            f"Checked {checked} item(s) with stored images; {verb} {broken}."
        )
