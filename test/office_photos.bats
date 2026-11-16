#!/usr/bin/env bats
# photos.js under node: picture sizes, the .crop sidecar, the crop square, and the folder scan
# (found, missing, unreadable, malformed sidecar). It has no herdr imports.

bats_require_minimum_version 1.5.0
load test_helper

photos_js() {
  command -v node >/dev/null || skip "node not installed"
  local d="$BATS_TEST_TMPDIR/photos"
  mkdir -p "$d"
  cp "$REPO_ROOT/office/crew-office/photos.js" "$d/photos.mjs"
  cat > "$d/run.mjs" <<JS
import * as P from "./photos.mjs";
import * as nodefs from "node:fs/promises";
const png = (w, h) => { const b = Buffer.alloc(33); Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]).copy(b); b.writeUInt32BE(13, 8); b.write("IHDR", 12); b.writeUInt32BE(w, 16); b.writeUInt32BE(h, 20); return b; };
const jpeg = (w, h) => Buffer.from([0xff,0xd8, 0xff,0xe0,0x00,0x04,0,0, 0xff,0xc0,0x00,0x11,0x08,h>>8,h&255,w>>8,w&255,3,1,0x22,0,2,0x11,1,3,0x11,1]);
const dir = process.env.DIR;
const w = (f, b) => nodefs.writeFile(dir + "/" + f, b);
$1
JS
  (cd "$d" && DIR="$BATS_TEST_TMPDIR/dir" node run.mjs)
}

setup() { mkdir -p "$BATS_TEST_TMPDIR/dir"; }

@test "imageSize reads PNG and JPEG headers, and refuses anything else" {
  run photos_js 'console.log(JSON.stringify([P.imageSize(png(640, 480)), P.imageSize(jpeg(300, 900)), P.imageSize(Buffer.from("hello world, not a picture")), P.imageSize(png(640, 480).subarray(0, 10)), P.imageSize(null)]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[{"w":640,"h":480},{"w":300,"h":900},null,null,null]' ]
}

@test "parseCrop: a valid line, a missing sidecar and malformed ones" {
  run photos_js 'console.log(JSON.stringify(["0.5 0.4 0.8\n", " .5   .5 1 ", null, "", "0.5 0.4", "a b c", "0.5 0.4 0", "0.5 0.4 1.5", "0.5 -1 0.5", "1 1 1\n2 2 1", "0.5 0.5 0.5 0.5"].map(P.parseCrop)));'
  [ "$status" -eq 0 ]
  [ "$output" = '[{"x":0.5,"y":0.4,"size":0.8},{"x":0.5,"y":0.5,"size":1},null,null,null,null,null,null,null,null,null]' ]
}

@test "squareOf: the largest centred square, from the top for a portrait; a crop is centre and size, kept inside" {
  run photos_js 'console.log(JSON.stringify([P.squareOf(800,400,null), P.squareOf(300,900,null), P.squareOf(500,500,null), P.squareOf(300,900,{x:.5,y:.6,size:.5}), P.squareOf(300,900,{x:0,y:0,size:1}), P.squareOf(300,900,{x:1,y:3,size:.5})]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[{"x":200,"y":0,"s":400},{"x":0,"y":0,"s":300},{"x":0,"y":0,"s":500},{"x":75,"y":465,"s":150},{"x":0,"y":0,"s":300},{"x":150,"y":750,"s":150}]' ]
}

@test "placement scales and shifts the picture so the square fills the box" {
  run photos_js 'console.log(JSON.stringify(P.placement(36, 800, 400, {x:200,y:0,s:400})));'
  [ "$status" -eq 0 ]
  [ "$output" = '{"width":72,"height":36,"left":-18,"top":0}' ]
}

@test "photoDirs: herdr-app's photos folder, after a prop folder only when it is under herdr-app's own" {
  run photos_js 'const A = "/h/.config/herdr-app"; console.log(JSON.stringify([P.photoDirs("/h", A), P.photoDirs("/h", A, "~/.config/herdr-app/crew/"), P.photoDirs("/h", A, "crew-photos"), P.photoDirs("/h", A, "~/pics"), P.photoDirs("/h", A, "/h/.config/larceny/photos"), P.photoDirs("/h", A, "crew/../../x"), P.photoDirs("/h", A, "/h/.config/herdr-app-evil/p"), P.photoDirs("/h", A, "  ")]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[["/h/.config/herdr-app/photos"],["/h/.config/herdr-app/crew","/h/.config/herdr-app/photos"],["/h/.config/herdr-app/crew-photos","/h/.config/herdr-app/photos"],["/h/.config/herdr-app/photos"],["/h/.config/herdr-app/photos"],["/h/.config/herdr-app/photos"],["/h/.config/herdr-app/photos"],["/h/.config/herdr-app/photos"]]' ]
}

@test "scanPhotos: found with its crop; no file means no entry; unreadable, empty and not-a-picture files are skipped; a bad sidecar gives no crop" {
  run photos_js '
await w("yoda.jpg", jpeg(300, 900)); await w("yoda.crop", "0.5 0.3 0.6\n");
await w("sara.PNG", png(200, 200)); await w("sara.crop", "garbage");
await w("amy.png", Buffer.alloc(0));
await w("sucre.jpg", Buffer.from("not a picture at all"));
await w("notes.txt", "hi");
await nodefs.mkdir(dir + "/broken.jpg");
const m = await P.scanPhotos(nodefs, [dir]);
const o = Object.fromEntries([...m].map(([k, v]) => [k, { ...v, path: v.path.slice(dir.length) }]));
console.log(JSON.stringify([o, m.has("whip")]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[{"sara":{"path":"/sara.PNG","w":200,"h":200,"crop":null},"yoda":{"path":"/yoda.jpg","w":300,"h":900,"crop":{"x":0.5,"y":0.3,"size":0.6}}},false]' ]
}

@test "scanPhotos: a missing folder gives nothing, and the first folder wins for a name" {
  run photos_js '
await nodefs.mkdir(dir + "/b"); await nodefs.mkdir(dir + "/a");
await nodefs.writeFile(dir + "/a/yoda.png", png(10, 10)); await nodefs.writeFile(dir + "/b/yoda.png", png(20, 20)); await nodefs.writeFile(dir + "/b/amy.png", png(30, 30));
const m = await P.scanPhotos(nodefs, [dir + "/nope", dir + "/a", dir + "/b"]);
console.log(JSON.stringify([[...m.keys()].sort(), m.get("yoda").w, (await P.scanPhotos(nodefs, [dir + "/nope"])).size]));'
  [ "$status" -eq 0 ]
  [ "$output" = '[["amy","yoda"],10,0]' ]
}

@test "imagePath is relative to herdr-app's folder" {
  run photos_js 'console.log(JSON.stringify(P.imagePath("/h/.config/herdr-app", "/h/.config/herdr-app/photos/a.jpg")));'
  [ "$status" -eq 0 ]
  [ "$output" = '"photos/a.jpg"' ]
}

@test "squareOf: Maya's Yoda sidecar 0.60 0.42 0.84 on the 1456x720 picture crops at x=571.2, y=0, side 604.8" {
  run photos_js 'const q = P.squareOf(1456, 720, P.parseCrop("0.60 0.42 0.84")); console.log(JSON.stringify([q.x, q.y, q.s].map((v) => Math.round(v * 10) / 10)));'
  [ "$status" -eq 0 ]
  [ "$output" = "[571.2,0,604.8]" ]
}
