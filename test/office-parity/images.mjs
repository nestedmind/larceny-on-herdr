// The overlay (the prototype at 50% over the office) and the diff (where they differ), made in headless Chrome.
// The office is drawn from what node recorded: the floor's own shapes, then each person as a disc and each name tag as a box.

import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Chrome } from "./chrome.mjs";

const S = 2; // px per world unit, as the prototype's canvas

const svgOf = (r, look) => {
  const { L, k, ops } = r;
  const paths = ops.map((o) => {
    const d = o.cmds.map((c) => (c[0] === "close" ? "Z" : (c[0] === "move_to" ? "M" : "L") + c[1].toFixed(2) + " " + c[2].toFixed(2))).join("");
    return `<path d="${d}" fill="${o.fill}"/>`;
  }).join("");
  const people = L.people.map((p) => `<circle cx="${p.x}" cy="${p.y}" r="4.5" fill="${look(p.id.startsWith("x:") ? p.name : p.id)[2]}" stroke="#fff" stroke-width="0.8"/>`).join("");
  const tags = L.people.map((p) => {
    const t = r.tags[p.agent ? p.agent.address : p.id];
    return t && t.w ? `<rect x="${t.x / k}" y="${t.y / k}" width="${t.w / k}" height="${(p.agent ? 34 : 17) / k}" rx="2" fill="#2b2f3a" opacity="0.7"/>` : "";
  }).join("");
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${L.W * S}" height="${L.H * S}" viewBox="0 0 ${L.W} ${L.H}" style="position:absolute;left:0;top:0">${paths}${people}${tags}</svg>`;
};

/** Writes <name>-overlay.png and <name>-diff.png in `dir`. `canvas` is the prototype's canvas as a data URL. */
export async function makeImages(dir, name, r, canvas, look) {
  const W = Math.ceil(Math.max(r.L.W, 480) * S), H = Math.ceil(Math.max(r.L.H, 288) * S);
  const svg = svgOf(r, look);
  const page = (extra) => `<!doctype html><meta charset="utf-8"><body style="margin:0;background:#fff"><div style="position:relative;width:${W}px;height:${H}px;background:#fff">${extra}</div>`;
  const proto = `<img src="${canvas}" style="position:absolute;left:0;top:0;width:960px;height:576px">`;
  const files = { overlay: page(svg + proto.replace("style=\"", "style=\"opacity:.5;")), diff: page(svg + proto.replace("style=\"", "style=\"mix-blend-mode:difference;")) };
  const chrome = await Chrome.launch({ width: W, height: H });
  try {
    const tmp = mkdtempSync(join(tmpdir(), "parity-img-"));
    for (const [kind, html] of Object.entries(files)) {
      const f = join(tmp, kind + ".html");
      writeFileSync(f, html);
      await chrome.open("file://" + f);
      await chrome.shot(join(dir, `${name}-${kind}.png`), W, H);
    }
  } finally { chrome.close(); }
}
