#!/usr/bin/env bats
# loh photos thumbs: small square copies of people's photos (ticket #35). The image tool is a fake that logs what it is asked.

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  D="$BATS_TEST_TMPDIR/photos"
  mkdir -p "$D" "$BATS_TEST_TMPDIR/bin"
  export FAKE_MAGICK_LOG="$BATS_TEST_TMPDIR/magick.log"
  : >"$FAKE_MAGICK_LOG"
  # identify prints FAKE_DIMS; any other call writes its last argument (without "png:") and logs its arguments.
  cat >"$BATS_TEST_TMPDIR/bin/magick" <<'EOS'
#!/usr/bin/env bash
if [[ "$1" == identify ]]; then echo -n "${FAKE_DIMS:-600 900}"; exit 0; fi
printf '%s\n' "$*" >>"$FAKE_MAGICK_LOG"
out="${*: -1}"; : >"${out#png:}"
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/magick"
  LOH="$REPO_ROOT/bin/loh"
}

with_fake() { PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$LOH" photos thumbs "$D"; }

@test "photos thumbs makes a 128 px square of the default crop, named with the crop key" {
  : >"$D/yoda.jpg"
  FAKE_DIMS="600 900" with_fake
  [ "$status" -eq 0 ]
  [[ "$output" == *"made yoda"* ]]
  [ -f "$D/.thumbs/yoda.default.png" ]
  grep -qF -- '-crop 600x600+0+0 +repage -filter Lanczos -resize 128x128' "$FAKE_MAGICK_LOG"
}

@test "photos thumbs applies the sidecar's crop, and a changed crop replaces the old thumb" {
  : >"$D/Yoda.JPG"
  printf '0.5 0.3 0.6\n' >"$D/yoda.crop"
  FAKE_DIMS="1000 1500" with_fake
  [ "$status" -eq 0 ]
  [ -f "$D/.thumbs/yoda.0.5-0.3-0.6.png" ]
  grep -qF -- '-crop 600x600+200+150 ' "$FAKE_MAGICK_LOG"
  printf '0.5 0.5 1\n' >"$D/yoda.crop"
  FAKE_DIMS="1000 1500" with_fake
  [ -f "$D/.thumbs/yoda.0.5-0.5-1.png" ]
  [ ! -e "$D/.thumbs/yoda.0.5-0.3-0.6.png" ]
}

@test "photos thumbs leaves an up-to-date thumb alone and redoes one whose picture is newer" {
  : >"$D/sara.png"
  with_fake
  : >"$FAKE_MAGICK_LOG"
  with_fake
  [[ "$output" == *"0 made, 1 up to date"* ]]
  [ ! -s "$FAKE_MAGICK_LOG" ]
  touch -d '+1 minute' "$D/sara.png"
  with_fake
  [[ "$output" == *"made sara"* ]]
}

@test "photos thumbs ignores a malformed sidecar, notes and the thumbs folder itself" {
  : >"$D/amy.webp"; printf 'nonsense\n' >"$D/amy.crop"; printf 'hi\n' >"$D/notes.txt"
  with_fake
  [ -f "$D/.thumbs/amy.default.png" ]
  [ "$(ls "$D/.thumbs" | wc -l)" -eq 1 ]
}

@test "photos thumbs skips a picture the tool cannot read and carries on" {
  : >"$D/amy.png"; : >"$D/yoda.png"
  cat >"$BATS_TEST_TMPDIR/bin/magick" <<'EOS'
#!/usr/bin/env bash
[[ "$1" == identify && "${*: -1}" == *amy.png* ]] && exit 1
if [[ "$1" == identify ]]; then echo -n "100 100"; exit 0; fi
out="${*: -1}"; : >"${out#png:}"
EOS
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr "$LOH" photos thumbs "$D"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"cannot read"*amy.png* ]]
  [ -f "$D/.thumbs/yoda.default.png" ]
  [ ! -e "$D/.thumbs/amy.default.png" ]
}

@test "photos thumbs with no image tool says so, exits 0 and writes nothing" {
  : >"$D/yoda.jpg"
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  for c in bash env dirname tr cat; do ln -s "$(command -v "$c")" "$BATS_TEST_TMPDIR/empty/$c"; done
  PATH="$BATS_TEST_TMPDIR/empty" run "$BATS_TEST_TMPDIR/empty/bash" "$REPO_ROOT/lib/loh/photos.sh" thumbs "$D"
  [ "$status" -eq 0 ]
  [[ "$output" == *"neither magick"* ]]
  [ ! -e "$D/.thumbs" ]
}

@test "photos thumbs wants the thumbs word and a folder that exists" {
  run --separate-stderr "$LOH" photos
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage: loh photos thumbs <folder>"* ]]
  run --separate-stderr "$LOH" photos thumbs "$D/nope"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"no such folder"* ]]
}

@test "photos thumbs, with ImageMagick installed, makes a real 128 px square" {
  command -v magick >/dev/null || skip "magick not installed"
  magick -size 300x200 xc:red "$D/yoda.png"
  run "$LOH" photos thumbs "$D"
  [ "$status" -eq 0 ]
  [ "$(magick identify -format '%wx%h' "$D/.thumbs/yoda.default.png")" = "128x128" ]
}
