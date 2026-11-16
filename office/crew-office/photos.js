// People's photos for the chat panel (ticket #35). Pure parts and one folder scan, with no herdr imports so they
// run under node in the tests. The photos live in a folder under herdr-app's own, one file per person named
// after them (`yoda.jpg`, `sara.png`), and nothing image-related is committed to the repo: anyone without a photo
// gets their floor figure (draw.js bustEl).

export const PHOTO_EXTS = ["jpg", "jpeg", "png", "webp", "gif"];

/**
 * The folders to look in, first match wins: the `photos` prop, then ~/.config/herdr-app/photos. herdr's image() loads
 * only from inside herdr-app's own folder, so the prop counts only when it names a folder under it (`~` and a path
 * relative to herdr-app's folder are understood); any other value, or one with a `..`, is ignored.
 */
export function photoDirs(home, appHome, prop) {
  const base = appHome.replace(/\/+$/, "");
  const out = [];
  if (typeof prop === "string" && prop.trim()) {
    let d = prop.trim().replace(/^~(?=\/|$)/, home).replace(/\/+$/, "");
    if (!d.startsWith("/")) d = `${base}/${d}`;
    if (d.startsWith(`${base}/`) && !d.split("/").includes("..") && d !== `${base}/photos`) out.push(d);
  }
  out.push(`${base}/photos`);
  return out;
}

/** The size in pixels of a PNG, JPEG, GIF or WebP from its first bytes, or null when it is none of them or cut short. */
export function imageSize(b) {
  if (!b || b.length < 12) return null;
  const u16 = (i) => (b[i] << 8) | b[i + 1];
  const u32 = (i) => ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0;
  const ok = (w, h) => (w > 0 && h > 0 ? { w, h } : null);
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return b.length >= 24 ? ok(u32(16), u32(20)) : null;
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return ok(b[6] | (b[7] << 8), b[8] | (b[9] << 8));
  if (b[0] === 0xff && b[1] === 0xd8) {
    let i = 2;
    while (i + 9 < b.length) {
      if (b[i] !== 0xff) { i++; continue; }
      const m = b[i + 1];
      if (m === 0xff) { i++; continue; }
      if (m === 0xd8 || m === 0x01 || (m >= 0xd0 && m <= 0xd7)) { i += 2; continue; }
      if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) return ok(u16(i + 7), u16(i + 5));
      i += 2 + u16(i + 2);
    }
    return null;
  }
  const tag = (i, s) => [...s].every((c, k) => b[i + k] === c.charCodeAt(0));
  if (tag(0, "RIFF") && tag(8, "WEBP") && b.length >= 30) {
    if (tag(12, "VP8X")) return ok(1 + (b[24] | (b[25] << 8) | (b[26] << 16)), 1 + (b[27] | (b[28] << 8) | (b[29] << 16)));
    if (tag(12, "VP8L")) { const v = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24); return ok(1 + (v & 0x3fff), 1 + ((v >>> 14) & 0x3fff)); }
    if (tag(12, "VP8 ")) return ok((b[26] | (b[27] << 8)) & 0x3fff, (b[28] | (b[29] << 8)) & 0x3fff);
  }
  return null;
}

/**
 * The sidecar `<name>.crop`: one line, `x y size`: the square's centre as fractions of the picture's width and height,
 * and its side as a fraction of the picture's short edge. Null for anything else (missing, empty, not three numbers, a size outside (0, 1.0]...), so the caller
 * falls back to the default crop.
 */
export function parseCrop(text) {
  if (typeof text !== "string") return null;
  const lines = text.split(/\r?\n/).filter((l) => l.trim());
  if (lines.length !== 1) return null;
  const parts = lines[0].trim().split(/\s+/);
  if (parts.length !== 3 || !parts.every((p) => /^[+-]?(\d+\.?\d*|\.\d+)$/.test(p))) return null;
  const [x, y, size] = parts.map(Number);
  if (!(size > 0 && size <= 1) || !(x >= 0 && x <= 1 && y >= 0 && y <= 1)) return null;
  return { x, y, size };
}

/** The crop's part of a thumbnail's name (`loh photos thumbs`): the sidecar's three numbers joined with "-", or "default". */
export function cropKey(text) {
  const crop = parseCrop(text);
  return crop ? text.trim().split(/\s+/).join("-") : "default";
}

/** `loh photos thumbs <folder>`: writes the small square copies the office draws (see scanPhotos). Run it where loh is found, in no workspace. */
export function thumbsCall(loh, dir) {
  return { cmd: loh || "loh", args: ["photos", "thumbs", dir], options: { timeout: 60000 } };
}

/**
 * The square taken from a w by h picture, in pixels: { x, y, s } with (x, y) its top left corner. By default the
 * largest centred square (from the top for a portrait, which is also its vertical centre for a landscape). With a crop, its centre (x of the width, y of the height, from the
 * picture's top left) and side (of the short edge), moved inside the picture when it would stick out.
 */
export function squareOf(w, h, crop) {
  const short = Math.min(w, h);
  if (!crop) return { x: (w - short) / 2, y: 0, s: short };
  const s = crop.size * short;
  const clamp = (v, hi) => Math.max(0, Math.min(hi, v));
  return { x: clamp(crop.x * w - s / 2, w - s), y: clamp(crop.y * h - s / 2, h - s), s };
}

/** Where the picture goes in a `size` px box so that `sq` fills it: the image's own size and its offset (both px). */
export function placement(size, w, h, sq) {
  const k = size / sq.s;
  return { width: w * k, height: h * k, left: -sq.x * k, top: -sq.y * k };
}

const extOf = (f) => (f.includes(".") ? f.slice(f.lastIndexOf(".") + 1).toLowerCase() : "");
const baseOf = (f) => f.slice(0, f.lastIndexOf(".")).toLowerCase();

/**
 * Reads the photo folders. `fs` has readdir and readFile (fs/promises). Returns Map(name -> { path, w, h, crop }).
 * A name is found in the first folder that has a readable picture for it. A file that cannot be read, or is not a
 * picture of a kind we know, is skipped as if absent; a missing or malformed sidecar gives crop null. Never throws.
 * herdr's image() does not smooth, so a big picture drawn small is grainy: when `loh photos thumbs` has made the
 * person's thumbnail (`.thumbs/<name>.<crop key>.png`, square, crop applied), that is what `path` names, with its own
 * size and no crop. Without one (not made yet, or no image tool) `path` is the picture itself.
 */
export async function scanPhotos(fs, dirs) {
  const found = new Map();
  for (const dir of dirs) {
    let names = [];
    try { names = await fs.readdir(dir); } catch (_) { continue; }
    let thumbs = [];
    try { thumbs = await fs.readdir(`${dir}/.thumbs`); } catch (_) { /* none made */ }
    const set = new Set(names);
    for (const f of [...names].sort()) {
      if (!PHOTO_EXTS.includes(extOf(f))) continue;
      const who = baseOf(f);
      if (!who || found.has(who)) continue;
      let size = null;
      try { size = imageSize(await fs.readFile(`${dir}/${f}`)); } catch (_) { continue; }
      if (!size) continue;
      let crop = null, key = "default";
      const side = names.find((n) => set.has(n) && n.toLowerCase() === `${who}.crop`);
      if (side) {
        try {
          const text = await fs.readFile(`${dir}/${side}`, "utf8");
          crop = parseCrop(text);
          key = cropKey(text);
        } catch (_) { crop = null; }
      }
      const thumb = thumbs.find((n) => n === `${who}.${key}.png`);
      if (thumb) {
        let ts = null;
        try { ts = imageSize(await fs.readFile(`${dir}/.thumbs/${thumb}`)); } catch (_) { /* fall back to the picture */ }
        if (ts) { found.set(who, { path: `${dir}/.thumbs/${thumb}`, w: ts.w, h: ts.h, crop: null }); continue; }
      }
      found.set(who, { path: `${dir}/${f}`, w: size.w, h: size.h, crop });
    }
  }
  return found;
}

/** The path `image()` takes: relative to herdr-app's folder, so a photo outside it goes by `..`. */
export function imagePath(appHome, file) {
  const a = appHome.replace(/\/+$/, "").split("/").filter(Boolean);
  const f = file.split("/").filter(Boolean);
  let i = 0;
  while (i < a.length && i < f.length - 1 && a[i] === f[i]) i++;
  return [...a.slice(i).map(() => ".."), ...f.slice(i)].join("/");
}
