from typing import Any

from django.core.management.base import BaseCommand

from foods.promotion import sweep


class Command(BaseCommand):
    help = (
        "Promote converged user nutrition edits to shared truth. Promotion "
        "also runs opportunistically on each proposal save; this sweep is a "
        "safety net for proposals that accumulated while thresholds changed."
    )

    def handle(self, *args: Any, **options: Any) -> None:
        promoted = sweep()
        self.stdout.write(f"Promoted {promoted} food item(s).")
