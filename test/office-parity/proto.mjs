// The design prototype, read in headless Chrome. Its script is a closure with no data export, so a temporary copy
// of the page gets one line added where the prototype already offers a test hook: its own ROOMS, DESKS, SPOTS,
// MATT_DESK, MEET_SEATS, DOG_BED and pathTo are then read as they are, never retyped. The original file is not touched.

import { readFileSync, writeFileSync, mkdtempSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { Chrome } from "./chrome.mjs";

// The prototype is gitignored, so a worktree does not have it: it is looked for in the main checkout (the parent of the git common dir).
const mainCheckout = () => {
  try {
    const common = execFileSync("git", ["-C", dirname(fileURLToPath(import.meta.url)), "rev-parse", "--path-format=absolute", "--git-common-dir"], { encoding: "utf8" }).trim();
    return dirname(common);
  } catch (_) { return process.cwd(); }
};
export const DEFAULT_PROTO = process.env.PARITY_PROTO || join(mainCheckout(), ".larceny", "office", "crew-office.html");
const HOOK = "hook.browser = { getS: () => S,";
const WORLD = "ROOMS, DESKS, SPOTS, MATT_DESK, MEET_SEATS, DOG_BED, HOME_DESK, PODS, PLACE_OF_THEN, pathTo, W, H, ";
// Animation stopped: no frame is ever scheduled, the page draws once when asked.
const FREEZE = "window.__crewOfficeTest = {}; window.requestAnimationFrame = () => 0;";

export async function openPrototype(file = DEFAULT_PROTO) {
  if (!existsSync(file)) throw new Error(`the prototype is not at ${file}: pass --proto <file> or set PARITY_PROTO`);
  const html = readFileSync(file, "utf8");
  if (!html.includes(HOOK)) throw new Error("the prototype's test hook line changed; update HOOK in proto.mjs");
  const copy = join(mkdtempSync(join(tmpdir(), "parity-proto-")), "crew-office.html");
  writeFileSync(copy, html.replace(HOOK, `hook.browser = { ${WORLD}getS: () => S,`));
  const chrome = await Chrome.launch({ width: 1600, height: 1000, before: FREEZE });
  await chrome.open("file://" + copy);
  const data = await chrome.eval(`(() => {
    const b = window.__crewOfficeTest.browser;
    const cs = getComputedStyle(document.documentElement);
    const pal = {};
    for (const n of Array.from(cs).concat(["--accent"])) if (/^--((fl|st)-|accent$|p-)/.test(n)) pal[n.slice(2)] = cs.getPropertyValue(n).trim();
    const strip = (o) => JSON.parse(JSON.stringify(o));
    return { W: b.W, H: b.H, ROOMS: strip(b.ROOMS), DESKS: strip(b.DESKS), MATT_DESK: strip(b.MATT_DESK), SPOTS: strip(b.SPOTS), MEET_SEATS: strip(b.MEET_SEATS),
      DOG_BED: strip(b.DOG_BED), HOME_DESK: strip(b.HOME_DESK), PODS: strip(b.PODS), PLACE_OF_THEN: strip(b.PLACE_OF_THEN), pal };
  })()`);
  return {
    data,
    /** The prototype's own pathTo for someone with this id at `from`, going to `to`. */
    pathTo: (id, from, to) => chrome.eval(`window.__crewOfficeTest.browser.pathTo(${JSON.stringify({ id, ...from })}, ${JSON.stringify(to)})`),
    /** Puts people where `places` says ({ id: {x, y} }), draws the canvas once, and gives it as a data URL (2 px a world unit). */
    canvas: (places = {}) => chrome.eval(`(() => {
      const b = window.__crewOfficeTest.browser, S = b.getS();
      for (const [id, p] of Object.entries(${JSON.stringify(places)})) if (S.ents[id]) { S.ents[id].x = p.x; S.ents[id].y = p.y; S.ents[id].path = []; }
      b.frame(0);
      return document.getElementById("cv").toDataURL("image/png");
    })()`),
    close: () => chrome.close(),
  };
}

/** The prototype's palette tokens (--fl-wall, --st-work, ...) as the office's PAL names them, in #rrggbb or #rrggbbaa. */
export function paletteOf(pal) {
  const hex = (s) => {
    s = s.trim().toLowerCase();
    const m = s.match(/^rgba?\(([^)]+)\)$/);
    if (m) {
      const [r, g, b, a = 1] = m[1].split(",").map((x) => parseFloat(x));
      const h = (n) => Math.round(n).toString(16).padStart(2, "0");
      return "#" + h(r) + h(g) + h(b) + (a < 1 ? h(a * 255) : "");
    }
    return s;
  };
  const camel = (k) => k.replace(/-([a-z0-9])/g, (_, c) => c.toUpperCase());
  const out = {};
  for (const [k, v] of Object.entries(pal)) {
    const name = k.replace(/^(fl|st)-/, "");
    let m;
    if ((m = k.match(/^p-([a-z]+)-(hair|skin|shirt)$/))) { ((out.people ||= {})[m[1]] ||= {})[m[2]] = hex(v); }
    else if ((m = name.match(/^mat-(api|web)$/))) { (out.mats ||= [])[m[1] === "api" ? 0 : 1] = hex(v); }
    else if ((m = name.match(/^book-(\d)$/))) { (out.books ||= [])[+m[1] - 1] = hex(v); }
    else if (k === "accent") out.accent = hex(v);
    else out[camel(name)] = hex(v);
  }
  return out;
}
