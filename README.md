DJI Importer
============

`dji_importer.py` is a small helper script for importing media from a DJI camera SD card into the macOS Photos app.

It is designed to:

- Scan an SD card for photo and video formats (JPG, MP4).
- Let you pick the SD card interactively (from `/Volumes`), or provide a path directly.
- Import all found media into Photos via AppleScript while asking Photos to skip already-imported items.

Requirements
------------

- macOS with the Photos app installed.
- Python 3 available as `python3` in your shell.
- The DJI camera is connected in SD card mode.


Basic Usage
-----------

From the repository root:

```bash
python3 dji_importer.py
```

When called without arguments, the script:

- Scans `/Volumes` for mounted volumes.
- Prints a numbered list of candidate volumes (typically including your SD card).
- Prompts you to:
  - Enter a number to choose one of the listed volumes, or
  - Type a custom path to your SD card (e.g. `/Volumes/DJI_SD_CARD`).

After you choose the SD card, the script:

1. Recursively scans for supported media files.
2. Prints a summary by file type.
3. Asks for confirmation before importing.


Command-Line Options
--------------------

You can also pass the SD card path directly:

```bash
python3 dji_importer.py /Volumes/DJI_SD_CARD
```

Available options:

- `sd_card` (positional, optional)  
  Path to the SD card root, e.g. `/Volumes/DJI_SD_CARD`.  
  If omitted, the script enters the interactive volume-selection flow described above.

- `--photos-library PATH`  
  Path to your Photos Library bundle (`.photoslibrary`).  
  Default: `~/Pictures/Photos Library.photoslibrary`.  
  This is only used to display which library will receive imports; the script does not touch its database.

- `--scan-only`  
  Only scan and print the media summary, do **not** import into Photos.

- `-y`, `--yes`  
  Skip the confirmation prompt and start importing immediately.


Import Behavior
---------------

For each file, the script uses AppleScript:

```applescript
tell application "Photos" to import POSIX file "/path/to/file" skip check duplicates true
```

This means:

- Photos is responsible for detecting duplicates.
- When a file has already been imported, Photos silently skips it instead of prompting.
- You can safely re-run the script on the same SD card; already-imported items will not be duplicated.

The script prints:

- A progress line for each file: `[current/total] Import: <relative path> ... OK/Failed`.
- A final summary:
  - Number of successfully imported files.
  - Number of failed files (if any), including basic error messages from AppleScript.


Notes and Tips
--------------

- If you see repeated failures, try:
  - Opening Photos manually once.
  - Ensuring the SD card is readable and not locked.
  - Re-running `dji_importer.py` with `--scan-only` first to confirm files are visible.
