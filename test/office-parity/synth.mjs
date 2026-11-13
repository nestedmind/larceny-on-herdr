#!/usr/bin/env node
// A stand-in for a shot of the live window, for testing live.mjs without one: the office's own floor shapes at 4 px a
// unit on a stage-coloured page, and each person of the crew drawn as a shirt-coloured body round a head, where the
// office's layout puts them. Options make it faulty on purpose.
//
//   node test/office-parity/synth.mjs --crew FILE --out FILE.png [--fault 1.1] [--hide id,id] [--mark]
//
//   --fault N   people are drawn N times further across than they should be (the floor is not)
//   --hide      leave these people out
//   --mark      paint a small square outside the floor (a change that is not in the floor)

import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Chrome } from "./chrome.mjs";
import { loadOffice } from "./office.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (name, fallback) => { const i = args.indexOf("--" + name); return i >= 0 ? args[i + 1] : fallback; };

const S = 4; // px a unit
const j = JSON.parse(readFileSync(opt("crew"), "utf8"));
const office = await loadOffice(resolve(opt("mod", join(here, "..", "..", "office", "crew-office"))));
const { crew } = office;
const L = crew.layoutCrew(crew.crewOf(j.terminals, crew.pickWorkspace(j.terminals, null)), j.repos || [], 1.6667);
const fault = parseFloat(opt("fault", "1"));
const hide = (opt("hide", "") || "").split(",");
const paths = office.draw.floorLayer(L, 1).ops.map((o) => {
  const d = o.cmds.map((c) => (c[0] === "close" ? "Z" : (c[0] === "move_to" ? "M" : "L") + c[1].toFixed(2) + " " + c[2].toFixed(2))).join("");
  return `<path d="${d}" fill="${o.fill}"/>`;
}).join("");
const people = L.people.filter((p) => p.id !== "dog" && !hide.includes(p.id)).map((p) => {
  const [hair, skin, shirt] = crew.look(p.id.startsWith("x:") ? p.name : p.id);
  const x = p.x * fault;
  return `<g opacity="${p.dim ? 0.7 : 1}"><ellipse cx="${x}" cy="${p.y}" rx="6.2" ry="4.8" fill="${shirt}"/><circle cx="${x}" cy="${p.y}" r="3.7" fill="${skin}"/><circle cx="${x}" cy="${p.y}" r="3" fill="${hair}"/></g>`;
}).join("");
const W = Math.ceil(L.W * S) + 80, H = Math.ceil(L.H * S) + 120;
const mark = args.includes("--mark") ? `<div style="position:absolute;left:4px;top:4px;width:24px;height:24px;background:#f00"></div>` : "";
const html = `<!doctype html><meta charset="utf-8"><body style="margin:0;background:#d5dae3"><div style="position:relative;width:${W}px;height:${H}px">${mark}<svg xmlns="http://www.w3.org/2000/svg" width="${L.W * S}" height="${L.H * S}" viewBox="0 0 ${L.W} ${L.H}" style="position:absolute;left:40px;top:60px;border-radius:6px">${paths}${people}</svg></div>`;
const page = join(mkdtempSync(join(tmpdir(), "parity-synth-")), "synth.html");
writeFileSync(page, html);
const chrome = await Chrome.launch({ width: W, height: H });
try { await chrome.open("file://" + page); await chrome.shot(resolve(opt("out")), W, H); } finally { chrome.close(); }
