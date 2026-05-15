from __future__ import annotations

import io

from PIL import Image

from foods.models import FoodItem

MAX_IMAGE_BYTES = 5 * 1024 * 1024
_ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/png", "image/webp"}


def images_ok(item: FoodItem) -> bool:
    return (
        bool(item.image_large and item.image_small)
        and item.image_status == FoodItem.IMAGE_STATUS_OK
    )


def validate_and_normalize_image(raw: bytes, declared_ct: str) -> bytes:
    ct = declared_ct.split(";")[0].strip().lower()
    if ct not in _ALLOWED_CONTENT_TYPES:
        raise ValueError(f"Unsupported image content type: {ct!r}.")
    if len(raw) > MAX_IMAGE_BYTES:
        raise ValueError("Image exceeds maximum allowed size.")
    try:
        Image.open(io.BytesIO(raw)).verify()
    except Exception as exc:
        raise ValueError("File is not a valid image.") from exc
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    out = io.BytesIO()
    img.save(out, format="JPEG", quality=85, optimize=True)
    return out.getvalue()


def safe_signature(signature: str | None) -> str:
    if not signature:
        return "image"
    safe = "".join(
        char for char in signature if char.isalnum() or char in ("-", "_", ".")
    )
    return safe or "image"
