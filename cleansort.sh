#!/bin/bash
#
# cleansort.sh
#
# Fixes the Image Capture / fi-8170 "double save" issue where some cards get
# saved TWICE: once in raw/untouched orientation, once with an EXIF rotation
# tag applied. This script:
#
#   1. Finds true duplicate pairs (same raw pixel content, created close
#      together in time) — NOT just visually-similar cards.
#   2. Keeps the correctly-oriented copy, moves the redundant raw copy to
#      a "_duplicates" subfolder (never deletes anything).
#   3. Bakes the EXIF rotation into the pixels of the kept file, so it
#      displays correctly even in software that ignores EXIF orientation.
#   4. Renames remaining files by creation-time order in front/back PAIRS:
#      the 1st file in the sequence is "<prefix>-1-front", the 2nd is
#      "<prefix>-1-back", the 3rd is "<prefix>-2-front", the 4th is
#      "<prefix>-2-back", and so on. Every two scans = one card.
#
# REQUIRES: python3 + Pillow
#   Install with:  pip3 install --user pillow
#
# USAGE:
#   ./cleansort.sh <folder> [prefix] [start_pair] [digits] [options]
#
#   prefix       Name prefix (default: card) -> card-1-front, card-1-back, ...
#   start_pair   Number of the first pair (default: 1)
#   digits       Zero-pad the pair number to this many digits (default: 0,
#                i.e. no padding: card-1-front, card-2-front, ... card-10-front.
#                Use e.g. 4 for card-0001-front if you have 1000+ pairs and
#                want filenames to sort correctly alongside each other.)
#
# OPTIONS:
#   --dry-run           Show what would happen; change nothing.
#   --window SECONDS    Max time gap between a duplicate pair (default: 5).
#   --threshold N        Mean pixel-difference threshold for "same image",
#                        0-255 scale (default: 4). Lower = stricter.
#
# EXAMPLES:
#   ./dedupe_and_rename_scans.sh ~/Scans card 1 0 --dry-run
#   ./dedupe_and_rename_scans.sh ~/Scans card 1 4
#
set -euo pipefail

FOLDER="${1:?Usage: $0 <folder> [prefix] [start_pair] [digits] [--dry-run] [--window SECONDS] [--threshold N]}"
PREFIX="${2:-$(date +"%Y-%m-%d-%H-%M")}"
START="${3:-1}"
DIGITS="${4:-5}"
DRYRUN="false"
WINDOW="5"
THRESHOLD="4"

shift 4 2>/dev/null || shift $#
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRYRUN="true"; shift ;;
    --window) WINDOW="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ ! -d "$FOLDER" ]]; then
  echo "Error: '$FOLDER' is not a directory." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 not found. Install Xcode command line tools (xcode-select --install)." >&2
  exit 1
fi

if ! python3 -c "import PIL" >/dev/null 2>&1; then
  echo "Error: Pillow is required. Install it with:  pip3 install --user pillow" >&2
  exit 1
fi

cd "$FOLDER"

python3 - "$PREFIX" "$START" "$DIGITS" "$DRYRUN" "$WINDOW" "$THRESHOLD" <<'PYEOF'
import os, sys, glob
from PIL import Image, ImageChops, ImageOps

prefix, start, digits, dry_run, window, threshold = (
    sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
    sys.argv[4] == "true", float(sys.argv[5]), float(sys.argv[6])
)

exts = ('jpg', 'jpeg', 'png', 'tif', 'tiff', 'bmp')
files = set()
for e in exts:
    files.update(glob.glob(f'*.{e}'))
    files.update(glob.glob(f'*.{e.upper()}'))
files = list(files)

if not files:
    print("No image files found in this folder.")
    sys.exit(0)

def birthtime(path):
    st = os.stat(path)
    return getattr(st, 'st_birthtime', st.st_mtime)

files.sort(key=birthtime)

def gray_thumb(path, max_dim=300):
    im = Image.open(path)
    im.load()
    g = im.convert('L')
    g.thumbnail((max_dim, max_dim))
    return im, g

def pair_filename(i, prefix, start, digits, ext):
    # i is the 0-based position in the final (deduped, time-sorted) sequence.
    # Even index (0, 2, 4...) = front of a new pair; odd index = back of
    # the pair that started at the previous even index.
    pair_number = start + i // 2
    side = 'front' if i % 2 == 0 else 'back'
    num_str = str(pair_number).zfill(digits) if digits > 0 else str(pair_number)
    return f"{prefix}-{num_str}-{side}{ext}"

def mean_abs_diff(g1, g2):
    if g1.size != g2.size:
        return None  # can't compare directly
    diff = ImageChops.difference(g1, g2)
    hist = diff.histogram()
    total = sum(hist)
    if total == 0:
        return 0.0
    return sum(i * c for i, c in enumerate(hist)) / total

# Cache: path -> (full image, gray thumb, orientation tag, birthtime)
cache = {}
for f in files:
    im, g = gray_thumb(f)
    orient = im.getexif().get(274, 1)
    cache[f] = {'gray': g, 'orient': orient, 'time': birthtime(f), 'raw_size': im.size}
    im.close()

consumed = set()
dup_pairs = []  # (keep, remove)

for i, f1 in enumerate(files):
    if f1 in consumed:
        continue
    t1 = cache[f1]['time']
    for f2 in files[i+1:]:
        if f2 in consumed:
            continue
        t2 = cache[f2]['time']
        if t2 - t1 > window:
            break  # sorted by time, no need to look further
        if cache[f1]['raw_size'] != cache[f2]['raw_size']:
            continue
        d = mean_abs_diff(cache[f1]['gray'], cache[f2]['gray'])
        if d is not None and d <= threshold:
            # Duplicate found. Prefer the one with a non-default orientation
            # tag (the intentionally-rotated copy). If tied, keep the earlier one.
            o1, o2 = cache[f1]['orient'], cache[f2]['orient']
            if o1 != 1 and o2 == 1:
                keep, remove = f1, f2
            elif o2 != 1 and o1 == 1:
                keep, remove = f2, f1
            else:
                keep, remove = f1, f2  # ambiguous — flagged below
                if o1 == o2:
                    print(f"  [!] Ambiguous pair (same orientation tag), keeping earlier by default: {f1} vs {f2}")
            dup_pairs.append((keep, remove))
            consumed.add(remove)
            break  # assume at most one duplicate per file

print(f"Found {len(files)} file(s) total, {len(dup_pairs)} duplicate pair(s).\n")

if dup_pairs:
    print("Duplicate pairs (keeping first, moving second to _duplicates/):")
    for keep, remove in dup_pairs:
        print(f"  KEEP {keep}   <->   MOVE {remove}")
    print()

if dry_run:
    print("[DRY RUN] No files were changed.")
    remaining = [f for f in files if f not in consumed]
    if len(remaining) % 2 != 0:
        print(f"\n[!] Warning: {len(remaining)} file(s) remain — that's an ODD number, "
              f"so the last file won't have a matching front/back partner. "
              f"Check the end of this list before running for real.")
    print(f"\n{len(remaining)} file(s) would remain and be renamed as pairs:")
    for i, f in enumerate(remaining):
        orient = cache[f]['orient']
        note = " (will bake in rotation)" if orient != 1 else ""
        ext = os.path.splitext(f)[1]
        final = pair_filename(i, prefix, start, digits, ext)
        print(f"  {f} -> {final}{note}")
    sys.exit(0)

# --- Apply changes ---

if dup_pairs:
    os.makedirs("_duplicates", exist_ok=True)
    with open("_duplicates/duplicate_log.txt", "a") as log:
        for keep, remove in dup_pairs:
            os.rename(remove, os.path.join("_duplicates", remove))
            log.write(f"kept={keep}  moved={remove}\n")

remaining = [f for f in files if f not in consumed]

if len(remaining) % 2 != 0:
    print(f"[!] Warning: {len(remaining)} file(s) remain — that's an ODD number, "
          f"so the last one has no front/back partner. It will still be renamed, "
          f"but double-check it afterward.")

# Bake in EXIF rotation for kept files that need it
for f in remaining:
    orient = cache[f]['orient']
    if orient != 1:
        im = Image.open(f)
        im2 = ImageOps.exif_transpose(im)
        exif = im2.getexif()
        if 274 in exif:
            del exif[274]
        im2.save(f, exif=exif, quality=95)
        im.close()
        im2.close()

# Renumber remaining files by creation time (two-pass, temp names first)
temp_names = []
for i, f in enumerate(remaining):
    ext = os.path.splitext(f)[1]
    tmp = f".__rename_tmp_{i}{ext}"
    os.rename(f, tmp)
    temp_names.append(tmp)

for i, tmp in enumerate(temp_names):
    ext = os.path.splitext(tmp)[1]
    final = pair_filename(i, prefix, start, digits, ext)
    os.rename(tmp, final)
    print(final)

print(f"\nDone. {len(remaining)} file(s) renamed as pairs. {len(dup_pairs)} duplicate(s) moved to _duplicates/.")
PYEOF