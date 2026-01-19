from __future__ import annotations

import ipaddress
import socket
from dataclasses import dataclass
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

from django.conf import settings
from django.core.files.base import ContentFile
from django.utils import timezone

from foods.models import FoodItem

MAX_IMAGE_BYTES = 5 * 1024 * 1024
READ_CHUNK_SIZE = 8192
REQUEST_TIMEOUT_SECONDS = 10


@dataclass
class ImageDownloadResult:
    success: bool
    error: str | None = None


def images_ok(item: FoodItem) -> bool:
    return (
        bool(item.image_large and item.image_small)
        and item.image_status == FoodItem.IMAGE_STATUS_OK
    )


def should_download_images(
    item: FoodItem,
    signature_changed: bool,
) -> bool:
    return signature_changed or not images_ok(item)


def download_food_images(
    item: FoodItem,
    large_url: str | None,
    small_url: str | None,
    image_signature: str | None,
) -> ImageDownloadResult:
    if not large_url or not small_url:
        item.image_status = FoodItem.IMAGE_STATUS_NONE
        item.image_downloaded_at = timezone.now()
        item.save(update_fields=["image_status", "image_downloaded_at"])
        return ImageDownloadResult(success=False, error="missing_urls")

    try:
        large_content = _fetch_image_bytes(large_url)
        small_content = _fetch_image_bytes(small_url)
    except (HTTPError, URLError, ValueError) as exc:
        item.image_status = FoodItem.IMAGE_STATUS_FAILED
        item.image_downloaded_at = timezone.now()
        item.save(update_fields=["image_status", "image_downloaded_at"])
        return ImageDownloadResult(success=False, error=str(exc))

    safe_signature = _safe_signature(image_signature)
    if item.image_large:
        item.image_large.delete(save=False)
    if item.image_small:
        item.image_small.delete(save=False)
    item.image_large.save(
        f"{safe_signature}_large.jpg",
        ContentFile(large_content),
        save=False,
    )
    item.image_small.save(
        f"{safe_signature}_small.jpg",
        ContentFile(small_content),
        save=False,
    )
    item.image_status = FoodItem.IMAGE_STATUS_OK
    item.image_downloaded_at = timezone.now()
    item.save()
    return ImageDownloadResult(success=True)


def _safe_signature(signature: str | None) -> str:
    if not signature:
        return "image"
    safe = "".join(
        char for char in signature if char.isalnum() or char in ("-", "_", ".")
    )
    return safe or "image"


class _SafeRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _validate_image_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _validate_image_url(url: str) -> None:
    parsed = urlparse(url)
    scheme = parsed.scheme.lower()
    if scheme not in ("http", "https"):
        raise ValueError("Unsupported image URL scheme.")
    hostname = parsed.hostname
    if not hostname:
        raise ValueError("Invalid image URL.")
    hostname = hostname.split("%", 1)[0]
    for ip in _resolve_host_addresses(hostname):
        # Reject non-global addresses (private, loopback, link-local, etc.).
        if not ip.is_global:
            raise ValueError("Blocked image URL host.")


def _resolve_host_addresses(
    hostname: str,
) -> list[ipaddress.IPv4Address | ipaddress.IPv6Address]:
    try:
        return [ipaddress.ip_address(hostname)]
    except ValueError:
        pass
    try:
        infos = socket.getaddrinfo(hostname, None)
    except socket.gaierror as exc:
        raise ValueError(f"Unable to resolve host: {hostname}") from exc
    addresses: list[ipaddress.IPv4Address | ipaddress.IPv6Address] = []
    for info in infos:
        address = info[4][0]
        try:
            addresses.append(ipaddress.ip_address(address))
        except ValueError:
            continue
    if not addresses:
        raise ValueError(f"Unable to resolve host: {hostname}")
    return addresses


def _fetch_image_bytes(url: str) -> bytes:
    _validate_image_url(url)
    user_agent = getattr(settings, "OFF_USER_AGENT", "FitnessApp/0.1 (images)")
    request = Request(url, headers={"User-Agent": user_agent})
    opener = build_opener(_SafeRedirectHandler())
    with opener.open(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        content_type = response.headers.get("Content-Type", "")
        if not content_type.startswith("image/"):
            raise ValueError(f"Unexpected content type: {content_type}")
        total = 0
        chunks: list[bytes] = []
        while True:
            chunk = response.read(READ_CHUNK_SIZE)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_IMAGE_BYTES:
                raise ValueError("Image exceeds max size.")
            chunks.append(chunk)
        if total == 0:
            raise ValueError("Empty image response.")
        return b"".join(chunks)
