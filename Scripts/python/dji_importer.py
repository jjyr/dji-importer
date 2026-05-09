#!/usr/bin/env python3
"""
Helper script for importing media from a DJI camera SD card into the macOS
Photos Library.

Features:
- Scan a given SD card path (or interactively choose a volume under /Volumes).
- Find media files (e.g. JPG/JPEG/MP4) on the SD card.
- Import all found files into the Photos app via AppleScript.
- Ask Photos to skip already-imported items (`skip check duplicates true`).
- Show progress and final results, including failures.

Notes:
- This script assumes you are using the macOS Photos app with a Photos Library.
- By default it targets `~/Pictures/Photos Library.photoslibrary`, but you can
  point it to another library with a command-line flag.
- The script does NOT read or modify the Photos Library database; Photos itself
  is responsible for detecting duplicates during import.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple


SUPPORTED_EXTENSIONS = {
    ".jpg",
    ".jpeg",
    ".mp4",
}


@dataclass
class MediaFile:
    path: Path
    name: str
    extension: str
    size: int


def scan_sd_card(root: Path, extensions: Set[str]) -> List[MediaFile]:
    root = root.expanduser().resolve()
    if not root.exists():
        raise FileNotFoundError(f"SD card path not found: {root}")
    if not root.is_dir():
        raise NotADirectoryError(f"SD card path is not a directory: {root}")

    media_files: List[MediaFile] = []
    for dirpath, _, filenames in os.walk(root):
        for filename in filenames:
            ext = Path(filename).suffix.lower()
            if ext not in extensions:
                continue
            full_path = Path(dirpath) / filename
            try:
                stat = full_path.stat()
            except OSError:
                continue
            media_files.append(
                MediaFile(
                    path=full_path,
                    name=filename,
                    extension=ext,
                    size=int(stat.st_size),
                )
            )

    media_files.sort(key=lambda m: (m.path.as_posix()))
    return media_files


def escape_for_applescript(s: str) -> str:
    """
    Escape a Python string for safe use inside an AppleScript string literal.

    Currently only escapes double quotes.
    """
    return s.replace('"', '\\"')


def import_file_into_photos(file_path: Path) -> Tuple[bool, str]:
    """
    Import a single file into Photos using AppleScript.

    Returns (success, extra_info).
    """
    posix_path = file_path.as_posix()
    # skip check duplicates true: Photos will quietly skip items that are
    # already imported instead of prompting for duplicates.
    script = (
        'tell application "Photos" to '
        f'import POSIX file "{escape_for_applescript(posix_path)}" '
        "skip check duplicates true"
    )

    max_total_wait = 15  # seconds
    wait_step = 5
    total_waited = 0
    last_output = ""

    while True:
        try:
            proc = subprocess.run(
                ["osascript", "-e", script],
                capture_output=True,
                text=True,
                check=False,
            )
        except FileNotFoundError:
            return False, "osascript not found; are you running on macOS?"

        output = (proc.stdout or "") + (proc.stderr or "")
        output = output.strip()

        if proc.returncode == 0:
            return True, output

        # Non-timeout error: do not retry.
        if "AppleEvent timed out" not in output:
            return False, output

        last_output = output

        if total_waited >= max_total_wait:
            # Reached maximum total wait time; give up.
            return False, last_output

        time.sleep(wait_step)
        total_waited += wait_step


def summarize_by_extension(files: Iterable[MediaFile]) -> Dict[str, int]:
    counts: Dict[str, int] = {}
    for f in files:
        ext = f.extension.lower()
        counts[ext] = counts.get(ext, 0) + 1
    return counts


def print_extension_summary(prefix: str, files: Sequence[MediaFile]) -> None:
    counts = summarize_by_extension(files)
    if not counts:
        print(f"{prefix}: 0")
        return
    parts = [f"{ext}={count}" for ext, count in sorted(counts.items())]
    print(f"{prefix}: {len(files)} files ({', '.join(parts)})")


def ask_yes_no(prompt: str, default: bool = False) -> bool:
    default_str = "Y/n" if default else "y/N"
    while True:
        ans = input(f"{prompt} [{default_str}]: ").strip().lower()
        if not ans:
            return default
        if ans in ("y", "yes"):
            return True
        if ans in ("n", "no"):
            return False
        print("Please enter y or n.")


def choose_sd_card_root() -> Path:
    """
    Scan volumes under /Volumes on macOS and let the user choose the SD card.

    If no suitable volume is detected or the user chooses "Other", allow
    entering a custom path.
    """
    volumes_root = Path("/Volumes")

    candidates: List[Path] = []
    root_stat: Optional[os.stat_result] = None
    try:
        root_stat = Path("/").stat()
    except OSError:
        root_stat = None

    if volumes_root.is_dir():
        for child in sorted(volumes_root.iterdir(), key=lambda p: p.name.lower()):
            if not child.is_dir():
                continue
            # Ignore hidden/system volumes.
            if child.name.startswith("."):
                continue
            # Ignore volumes that point to the same device as the root
            # filesystem (e.g. "Macintosh HD").
            if root_stat is not None:
                try:
                    st = child.stat()
                except OSError:
                    st = None
                if st is not None and st.st_dev == root_stat.st_dev:
                    continue
            candidates.append(child)

    if not candidates:
        print("No suitable volumes detected under /Volumes. Please type the SD card path manually.")
        while True:
            text = input("Enter SD card path: ").strip()
            if not text:
                continue
            path = Path(text).expanduser()
            if path.exists() and path.is_dir():
                return path
            print(f"Invalid or non-existent path: {path}")

    print("Detected volumes (your SD card is usually one of these):")
    for idx, vol in enumerate(candidates, start=1):
        print(f"  [{idx}] {vol}")
    print(f"  [{len(candidates) + 1}] Other path (type manually)")

    while True:
        choice = input(
            f"Choose SD card index (1-{len(candidates) + 1}), or enter a path directly: "
        ).strip()
        if not choice:
            continue

        # Numeric choice.
        if choice.isdigit():
            num = int(choice)
            if 1 <= num <= len(candidates):
                return candidates[num - 1]
            if num == len(candidates) + 1:
                # Other path.
                while True:
                    text = input("Enter SD card path: ").strip()
                    if not text:
                        continue
                    path = Path(text).expanduser()
                    if path.exists() and path.is_dir():
                        return path
                    print(f"Invalid or non-existent path: {path}")
            print("Index out of range.")
            continue

        # User typed a path directly.
        path = Path(choice).expanduser()
        if path.exists() and path.is_dir():
            return path
        print(f"Invalid or non-existent path: {path}")


def run(args: argparse.Namespace) -> int:
    if args.sd_card:
        sd_root = Path(args.sd_card).expanduser()
    else:
        sd_root = choose_sd_card_root()

    photos_library = Path(args.photos_library).expanduser()

    print(f"SD card path: {sd_root}")
    print(f"Photos Library path: {photos_library}")

    try:
        media_files = scan_sd_card(sd_root, SUPPORTED_EXTENSIONS)
    except (FileNotFoundError, NotADirectoryError) as exc:
        print(f"[ERROR] {exc}")
        return 1

    if not media_files:
        print("No supported media files found on SD card.")
        return 0

    print_extension_summary("SD card media files", media_files)

    if args.scan_only:
        print("Scan-only mode (--scan-only); no import will be performed.")
        return 0

    if not args.yes and not ask_yes_no(
        f"Import {len(media_files)} files into Photos?", default=False
    ):
        print("Import cancelled.")
        return 0

    print("Starting import into Photos (the Photos app may be launched automatically)...")

    successes: List[MediaFile] = []
    failures: List[Tuple[MediaFile, str]] = []

    total = len(media_files)
    for idx, media in enumerate(media_files, start=1):
        rel_path = media.path.relative_to(sd_root) if media.path.is_relative_to(sd_root) else media.path
        print(f"[{idx}/{total}] Importing: {rel_path} ... ", end="")
        ok, info = import_file_into_photos(media.path)
        if ok:
            print("OK")
            successes.append(media)
        else:
            print("FAILED")
            if info:
                print(f"    Reason: {info}")
            failures.append((media, info))

    print("\nImport finished.")
    print(f"Successfully imported: {len(successes)} files")
    print(f"Failed to import: {len(failures)} files")

    if failures:
        print("\nThe following files failed to import:")
        for media, reason in failures:
            rel_path = media.path.relative_to(sd_root) if media.path.is_relative_to(sd_root) else media.path
            if reason:
                print(f"- {rel_path}  (reason: {reason})")
            else:
                print(f"- {rel_path}")
        print(
            "\nYou can check the failure reasons (for example, Photos not "
            "authorized, disk read-only, etc.), then run this script again. "
            "Files that have already been imported usually will not be "
            "imported again by Photos."
        )

    return 0


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Scan a DJI camera SD card and import photos/videos into the macOS Photos Library.",
    )
    parser.add_argument(
        "sd_card",
        nargs="?",
        help="SD card mount path, e.g. /Volumes/NO_NAME; if omitted, volumes under /Volumes will be listed for selection",
    )
    parser.add_argument(
        "--photos-library",
        default=str(Path.home() / "Pictures" / "Photos Library.photoslibrary"),
        help="Path to Photos Library bundle (.photoslibrary). Default: ~/Pictures/Photos Library.photoslibrary",
    )
    parser.add_argument(
        "--scan-only",
        action="store_true",
        help="Only scan and show report; do not import into Photos.",
    )
    parser.add_argument(
        "-y",
        "--yes",
        action="store_true",
        help="Do not ask for confirmation; start importing immediately.",
    )
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    try:
        return run(args)
    except KeyboardInterrupt:
        print("\nInterrupted.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
