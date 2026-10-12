#!/usr/bin/env python3
"""Wikimedia Commons Picture of the Day wallpaper manager (stdlib only)."""
from __future__ import annotations

import argparse
from datetime import date, datetime, timedelta, timezone
from html import unescape
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, unquote, urlparse, parse_qs
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

API_URL = "https://commons.wikimedia.org/w/api.php"
RSS_URL = API_URL + "?" + urlencode({"action": "featuredfeed", "feed": "potd", "feedformat": "rss", "language": "en"})
DATA_DIR = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share") / "commons-potd-wallpaper"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "commons-potd-wallpaper"
IMG_DIR = DATA_DIR / "images"
STATE_FILE = CACHE_DIR / "state"
METADATA_FILE = DATA_DIR / "metadata.json"
SAVE_DIR = Path(os.environ.get("POTD_SAVE_DIR") or Path.home() / "Pictures/wikimedia").expanduser()
EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".tif", ".tiff", ".webp", ".svg"}
USER_AGENT = "commons-potd-wallpaper/2.0 (Python standard library)"


class PotdError(Exception):
    pass


def fetch(url: str, *, timeout: int = 45) -> bytes:
    req = Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(req, timeout=timeout) as response:
            return response.read()
    except (HTTPError, URLError, TimeoutError, OSError) as exc:
        raise PotdError(f"Could not retrieve {url}: {exc}") from exc


def api_query(**params: str | int) -> dict:
    params.setdefault("format", "json")
    url = API_URL + "?" + urlencode(params)
    try:
        result = json.loads(fetch(url))
    except (ValueError, UnicodeError) as exc:
        raise PotdError("Wikimedia API returned invalid JSON") from exc
    if not isinstance(result, dict) or "error" in result:
        raise PotdError(f"Wikimedia API error: {result.get('error', result)}")
    return result


def atomic_json_write(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=path.name + ".tmp.", delete=False) as handle:
            temp_path = Path(handle.name)
            json.dump(value, handle, ensure_ascii=False, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
    finally:
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)


def load_json(path: Path, *, default: dict | None = None) -> dict:
    if not path.exists():
        return {} if default is None else default
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError) as exc:
        raise PotdError(f"Invalid or unreadable JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise PotdError(f"Expected a JSON object in {path}")
    return value


def metadata_root() -> dict:
    root = load_json(METADATA_FILE)
    # Original script treated schema-versioned metadata as an incompatible format.
    return {} if "schema_version" in root else root


def image_title_from_url(url: str) -> str:
    parsed = urlparse(url)
    match = re.search(r"/wiki/(File:[^/?#]+)", parsed.path)
    if match:
        return unquote(match.group(1))
    title = parse_qs(parsed.query).get("title", [""])[0]
    return title if title.startswith("File:") else ""


def todays_potd() -> tuple[str, str, str]:
    try:
        root = ET.fromstring(fetch(RSS_URL))
    except ET.ParseError as exc:
        raise PotdError(f"Invalid POTD RSS: {exc}") from exc
    item = root.find("./channel/item")
    if item is None:
        raise PotdError("POTD RSS contains no items")
    fields = {name: item.findtext(name, default="") or "" for name in ("title", "link", "guid", "description")}
    entry_id = fields["guid"] or fields["link"]
    title = fields["title"] if fields["title"].startswith("File:") else ""
    title = title or image_title_from_url(fields["link"]) or image_title_from_url(fields["guid"])
    if not title:
        match = re.search(r"File:[^<>\"'\s]+\.(?:jpg|jpeg|png|gif|tif|tiff|webp|svg)",
                          fields["description"], re.IGNORECASE)
        title = match.group(0) if match else ""
    if not title:
        raise PotdError("Could not extract File: title from RSS item")
    return title.replace(" ", "_"), entry_id, ""


def random_potd(start: date, tries: int) -> tuple[str, str, str]:
    today = datetime.now(timezone.utc).date()
    if start > today:
        raise PotdError("--random-start cannot be in the future")
    for _ in range(tries):
        selected = start + timedelta(days=random.randint(0, (today - start).days))
        try:
            response = api_query(action="expandtemplates", text="{{Potd/" + selected.isoformat() + "}}",
                                 prop="wikitext")
        except PotdError as exc:
            print(f"Warning: random POTD lookup failed: {exc}", file=sys.stderr)
            continue
        filename = response.get("expandtemplates", {}).get("wikitext", "")
        if not isinstance(filename, str):
            continue
        filename = filename.replace("\r", "").replace("\n", "").strip()
        title = filename if filename.startswith("File:") else "File:" + filename
        if Path(title).suffix.lower() not in EXTENSIONS:
            continue
        return title.replace(" ", "_"), f"random:{selected.isoformat()}:{int(time.time())}", selected.isoformat()
    raise PotdError(f"Failed to pick a random POTD after {tries} tries")


def image_info(title: str, max_width: int) -> dict:
    response = api_query(action="query", titles=title, prop="imageinfo",
                         iiprop="url|size|mime|mediatype|extmetadata", iiurlwidth=max_width)
    pages = response.get("query", {}).get("pages", {})
    page = next(iter(pages.values()), {})
    infos = page.get("imageinfo", [])
    info = infos[0] if infos else {}
    if not info.get("url") and not info.get("thumburl"):
        raise PotdError(f"MediaWiki API did not return a usable URL for {title}")
    return info


def metadata_key(info: dict, title: str) -> str:
    fallback = title.removeprefix("File:").replace("_", " ")
    name = info.get("extmetadata", {}).get("ObjectName", {}).get("value") or fallback
    name = re.sub(r"\s+", " ", str(name)).strip()
    return name or title.removeprefix("File:")


def compact_info(info: dict, key: str) -> dict:
    metadata = info.get("extmetadata", {})
    return {field: metadata.get(field, {"value": default}) for field, default in
            (("ObjectName", key), ("ImageDescription", ""), ("DateTimeOriginal", ""))}


def download_image(url: str, destination: Path) -> bool:
    if destination.is_file():
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".potd-download-", delete=False) as handle:
            temp_path = Path(handle.name)
            for attempt in range(3):
                try:
                    request = Request(url, headers={"User-Agent": USER_AGENT})
                    with urlopen(request, timeout=90) as response:
                        shutil.copyfileobj(response, handle)
                    break
                except (HTTPError, URLError, TimeoutError, OSError) as exc:
                    if attempt == 2:
                        raise PotdError(f"Image download failed: {exc}") from exc
                    handle.seek(0)
                    handle.truncate()
                    time.sleep(2)
            handle.flush()
            os.fsync(handle.fileno())
        if temp_path.stat().st_size == 0:
            raise PotdError("Downloaded image is empty")
        os.replace(temp_path, destination)
        return True
    finally:
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)


def current_state() -> dict:
    if not STATE_FILE.exists():
        return {}
    try:
        return load_json(STATE_FILE)
    except PotdError:
        # Previous script also accepted the older 'entry_id|file_title' format.
        try:
            raw = STATE_FILE.read_text(encoding="utf-8").strip()
        except OSError:
            return {}
        if "|" in raw:
            entry_id, title = raw.split("|", 1)
            return {"entry_id": entry_id, "file_title": title}
        return {}


def already_applied(entry_id: str, title: str) -> bool:
    state = current_state()
    return state.get("entry_id") == entry_id and state.get("file_title") == title


def set_wallpaper(path: Path) -> None:
    uri = path.resolve().as_uri()
    if shutil.which("gsettings"):
        for key in ("picture-uri", "picture-uri-dark"):
            writable = subprocess.run(["gsettings", "writable", "org.gnome.desktop.background", key],
                                      capture_output=True, text=True, check=False)
            if writable.returncode == 0 and writable.stdout.strip() == "true":
                subprocess.run(["gsettings", "set", "org.gnome.desktop.background", key, uri],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if shutil.which("plasma-apply-wallpaperimage"):
        subprocess.run(["plasma-apply-wallpaperimage", str(path)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def clean_cache(keep: int) -> None:
    if keep <= 0 or not IMG_DIR.exists():
        return
    files = sorted((p for p in IMG_DIR.iterdir() if p.is_file()),
                   key=lambda p: p.stat().st_mtime, reverse=True)
    for path in files[keep:]:
        try:
            path.unlink()
        except OSError as exc:
            print(f"Warning: could not remove {path}: {exc}", file=sys.stderr)


def clean_html(value: object) -> str:
    text = "" if value is None else str(value)
    text = re.sub(r"<[^>]*>", "", text)
    return " ".join(unescape(text).split())


def print_info() -> None:
    if not METADATA_FILE.is_file():
        raise PotdError("No metadata found. Run --force or --random first")
    root = metadata_root()
    state = current_state()
    key = state.get("metadata_key", "")
    if key not in root:
        key = max(root, key=lambda k: root[k].get("time_downloaded", ""), default="")
    if not key:
        raise PotdError("No compact metadata entry found. Run --force or --random first")
    entry = root[key]
    info = entry.get("image_info", {})
    values = [info.get("ObjectName", {}).get("value", key),
              info.get("ImageDescription", {}).get("value", ""),
              info.get("DateTimeOriginal", {}).get("value", ""),
              entry.get("image_url", ""), entry.get("time_downloaded", "")]
    print(" ".join(filter(None, (clean_html(value) for value in values))))


def save_wallpaper() -> None:
    state = current_state()
    source = Path(state.get("display_path") or "/nonexistent")
    if not source.is_file():
        raise PotdError("Current wallpaper file is not available. Run --force or --random first")
    SAVE_DIR.mkdir(parents=True, exist_ok=True)
    key = state.get("metadata_key") or "wikimedia-potd"
    safe_name = re.sub(r"_+", "_", re.sub(r"[^A-Za-z0-9._-]", "_", key)).strip("_") or "wikimedia-potd"
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    extension = source.suffix.lower() if source.suffix.lower() in EXTENSIONS else ""
    target = SAVE_DIR / f"{timestamp}_{safe_name}{extension}"
    shutil.copy2(source, target)
    target.chmod(0o644)
    print(f"Saved current POTD wallpaper to: {target}")


def positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Set Wikimedia Commons Picture of the Day as wallpaper")
    parser.add_argument("--force", action="store_true", help="Apply even if already applied")
    parser.add_argument("--download-only", action="store_true", help="Download without changing wallpaper")
    parser.add_argument("--max-width", type=positive_int, default=int(os.environ.get("MAX_WIDTH", "3840")))
    parser.add_argument("--keep", type=int, default=int(os.environ.get("KEEP", "30")))
    parser.add_argument("--random", action="store_true", help="Choose a random historical POTD")
    parser.add_argument("--random-start", default="2004-12-15", metavar="DATE")
    parser.add_argument("--random-tries", type=positive_int, default=30, metavar="N")
    parser.add_argument("--info", action="store_true", help="Print current wallpaper metadata")
    parser.add_argument("--save", action="store_true", help="Save current wallpaper to POTD_SAVE_DIR")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.info:
        print_info()
        return 0
    if args.save:
        save_wallpaper()
        return 0
    IMG_DIR.mkdir(parents=True, exist_ok=True)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    if args.random:
        try:
            start = date.fromisoformat(args.random_start)
        except ValueError as exc:
            raise PotdError(f"Invalid --random-start date: {args.random_start}") from exc
        title, entry_id, potd_date = random_potd(start, args.random_tries)
    else:
        title, entry_id, potd_date = todays_potd()
    if not (args.force or args.random) and already_applied(entry_id, title):
        return 0
    info = image_info(title, args.max_width)
    orig_url = info.get("url", "")
    thumb_url = info.get("thumburl", "")
    download_url = thumb_url if thumb_url and int(info.get("width") or 0) > args.max_width else orig_url
    if not download_url:
        download_url = thumb_url
    prefix = f"potd_{potd_date}" if potd_date else date.today().isoformat()
    base = title.removeprefix("File:").replace("/", "_")
    destination = IMG_DIR / f"{prefix}_{base}"
    downloaded = download_image(download_url, destination)
    key = metadata_key(info, title)
    root = metadata_root()
    previous = root.get(key, {})
    downloaded_at = (datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                     if downloaded else previous.get("time_downloaded") or
                     datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    root[key] = {"image_url": download_url, "time_downloaded": downloaded_at,
                 "image_info": compact_info(info, key)}
    atomic_json_write(METADATA_FILE, root)
    if not args.download_only:
        set_wallpaper(destination)
        atomic_json_write(STATE_FILE, {"entry_id": entry_id, "file_title": title,
                                       "metadata_key": key, "display_path": str(destination)})
    clean_cache(args.keep)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (PotdError, OSError, ValueError) as exc:
        print(f"commons-potd-wallpaper: {exc}", file=sys.stderr)
        sys.exit(1)
