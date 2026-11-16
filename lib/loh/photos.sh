# shellcheck shell=bash
# loh photos thumbs <folder>: small square copies of the people's photos, for the office chat panel.
#
# herdr's image() draws without smoothing, so a picture of about 1000 px shrunk to a 32 px avatar
# comes out grainy. For each picture in <folder> (one file per person, named after them:
# yoda.jpg, sara.png; JPEG, PNG, WebP or GIF) this writes <folder>/.thumbs/<name>.<crop>.png:
# THUMB_PX square, the photo's crop (its <name>.crop sidecar, else the default centred square)
# already applied, resized with a smoothing filter. <crop> is the sidecar's three numbers joined
# with "-", or "default", so a changed crop is a new file and the old one goes. A thumb is made again
# when its picture is newer than it.
#
# Tools, first found: magick (ImageMagick), then python3 with PIL. With neither it says so and
# exits 0: no thumbnails, and the office draws the full pictures as before. Prints "made <name>"
# for each thumb it writes. A picture that cannot be read is reported on stderr and skipped.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

THUMB_PX=128

usage() {
  echo "Usage: loh photos thumbs <folder>" >&2
  exit 2
}

[[ $# -eq 2 && "$1" == thumbs ]] || usage
dir="${2%/}"
[[ -d "$dir" ]] || die "no such folder: $dir"

tool=""
if command -v magick >/dev/null 2>&1; then
  tool=magick
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import PIL' >/dev/null 2>&1; then
  tool=pil
fi
if [[ -z "$tool" ]]; then
  echo "no thumbnails made: neither magick (ImageMagick) nor python3 with PIL is installed; the office draws the full pictures"
  exit 0
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# size_of <file>: "<width> <height>" of the picture's first frame.
size_of() {
  if [[ "$tool" == magick ]]; then
    magick identify -format '%w %h' "$1[0]"
  else
    python3 -c 'from PIL import Image; import sys; print(*Image.open(sys.argv[1]).size)' "$1"
  fi
}

# shrink <file> <x> <y> <side> <out>: the square at (x, y), THUMB_PX wide, as a PNG.
shrink() {
  if [[ "$tool" == magick ]]; then
    magick "$1[0]" -crop "${4}x${4}+$2+$3" +repage -filter Lanczos -resize "${THUMB_PX}x${THUMB_PX}" "png:$5"
  else
    python3 -c 'import sys; from PIL import Image
f, x, y, s, out, px = sys.argv[1], *map(int, sys.argv[2:5]), sys.argv[5], int(sys.argv[6])
im = Image.open(f).convert("RGBA").crop((x, y, x + s, y + s)).resize((px, px), Image.LANCZOS)
im.save(out, "PNG")' "$1" "$2" "$3" "$4" "$5" "$THUMB_PX"
  fi
}

# crop_of <sidecar>: the sidecar's "x y size" when it is one line of three numbers (x and y 0 to 1, size above 0 up to 1), else nothing.
crop_of() {
  [[ -f "$1" ]] || return 0
  local text
  text="$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null || true)"
  [[ -n "$text" && "$text" != *$'\n'* ]] || return 0
  awk -v t="$text" 'BEGIN {
    if (split(t, p, " ") != 3) exit
    for (i = 1; i <= 3; i++) if (p[i] !~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)$/) exit
    if (!(p[3] + 0 > 0 && p[3] + 0 <= 1 && p[1] + 0 >= 0 && p[1] + 0 <= 1 && p[2] + 0 >= 0 && p[2] + 0 <= 1)) exit
    print p[1], p[2], p[3]
  }'
}

# square_of <w> <h> [<cx> <cy> <size>]: "x y side" in whole pixels, as the office's squareOf() takes it.
square_of() {
  awk -v w="$1" -v h="$2" -v cx="${3:-}" -v cy="${4:-}" -v sz="${5:-}" 'BEGIN {
    short = (w < h) ? w : h
    if (cx == "") { s = short; x = (w - short) / 2; y = 0 }
    else { s = sz * short; x = cx * w - s / 2; y = cy * h - s / 2 }
    s = int(s + 0.5); if (s < 1) s = 1; if (s > short) s = short
    x = int(x + 0.5); y = int(y + 0.5)
    if (x < 0) x = 0; if (x > w - s) x = w - s
    if (y < 0) y = 0; if (y > h - s) y = h - s
    print x, y, s
  }'
}

thumbs="$dir/.thumbs"
seen=" "
made=0 fresh=0
for f in "$dir"/*; do
  [[ -f "$f" ]] || continue
  base="$(lower "${f##*/}")"
  case "$base" in
    *.jpg | *.jpeg | *.png | *.webp | *.gif) ;;
    *) continue ;;
  esac
  who="${base%.*}"
  [[ -n "$who" && "$seen" != *" $who "* ]] || continue
  seen+="$who "

  side=""
  for c in "$dir"/*; do
    [[ "$(lower "${c##*/}")" == "$who.crop" ]] && { side="$c"; break; }
  done
  crop="$(crop_of "$side")"
  key="default"
  # shellcheck disable=SC2086
  [[ -z "$crop" ]] || key="$(set -- $crop; echo "$1-$2-$3")"
  out="$thumbs/$who.$key.png"

  if [[ -f "$out" && ! "$f" -nt "$out" ]]; then
    fresh=$((fresh + 1))
    continue
  fi
  if ! size="$(size_of "$f" 2>/dev/null)" || [[ ! "$size" =~ ^[0-9]+\ [0-9]+$ ]]; then
    echo "loh: cannot read $f; skipped" >&2
    continue
  fi
  # shellcheck disable=SC2086
  read -r x y s <<<"$(square_of $size $crop)"
  mkdir -p "$thumbs"
  tmp="$thumbs/.$who.$$.png"
  if ! shrink "$f" "$x" "$y" "$s" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "loh: cannot make a thumbnail of $f; skipped" >&2
    continue
  fi
  mv -f "$tmp" "$out"
  # An older thumb of this person with another crop is no longer wanted.
  for old in "$thumbs/$who."*.png; do
    [[ -e "$old" && "$old" != "$out" ]] && rm -f "$old"
  done
  echo "made $who"
  made=$((made + 1))
done
echo "thumbs: $made made, $fresh up to date ($tool)"
