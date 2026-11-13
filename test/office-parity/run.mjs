#!/usr/bin/env node
// The geometry part of the office parity check: the office's layout and render under node, against the prototype read
// in headless Chrome. No window is needed. Exits 0 when nothing differs by more than 1 px and no colour differs, 1 when
// something does, 2 when it could not run. The live part (live.mjs) measures the real window.
//
//   node test/office-parity/run.mjs [--proto FILE] [--mod DIR] [--case NAME] [--images] [--out DIR] [--all] [--json]

import { mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { CASES, KNOWN, ROUTE } from "./cases.mjs";
import { compareCase, comparePalette, LIMIT } from "./compare.mjs";
import { loadOffice, drawOffice } from "./office.mjs";
import { DEFAULT_PROTO, openPrototype, paletteOf } from "./proto.mjs";
import { makeImages } from "./images.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (name, fallback) => { const i = args.indexOf("--" + name); return i >= 0 ? args[i + 1] : fallback; };
const flag = (name) => args.includes("--" + name);

const mod = resolve(opt("mod", join(here, "..", "..", "office", "crew-office")));
const only = opt("case");
const shown = flag("all") ? Infinity : 8;

// Splits a case's findings into those a KNOWN entry covers (same case, check, id, field and size) and the rest, and finds the
// entries that matched nothing: those fail too, so the list empties as the office is fixed.
function sortKnown(name, findings) {
  const mine = KNOWN.filter((e) => e.case === name);
  const hit = new Set();
  const known = [], fresh = [];
  for (const f of findings) {
    const e = mine.find((x) => x.check === f.group && x.id === f.id && x.field === f.field && Math.abs(x.off - f.off) <= 0.1);
    if (e) { hit.add(e); known.push({ ...f, ticket: e.ticket }); } else fresh.push(f);
  }
  return { known, fresh, stale: mine.filter((e) => !hit.has(e)) };
}

function print(name, k, res, sorted) {
  console.log(`\n== ${name}  (scale ${k.toFixed(3)}; ${res.counted} values checked; ${sorted.fresh.length} differ by more than ${LIMIT} px, ${sorted.known.length} known)`);
  const groups = new Map();
  for (const f of sorted.fresh) (groups.get(f.group) || groups.set(f.group, []).get(f.group)).push(f);
  for (const [g, list] of groups) {
    console.log(`  ${g}: ${list.length}`);
    for (const f of list.slice(0, shown)) console.log(`    ${f.id} ${f.field}: office ${JSON.stringify(f.got)}, prototype ${JSON.stringify(f.want)}, off by ${f.off} px`);
    if (list.length > shown) console.log(`    ... ${list.length - shown} more (--all lists them)`);
  }
  for (const f of sorted.known) console.log(`  known (${f.ticket}): ${f.group} ${f.id} ${f.field}: office ${JSON.stringify(f.got)}, prototype ${JSON.stringify(f.want)}, off by ${f.off} px`);
  for (const e of sorted.stale) console.log(`  STALE known entry (${e.ticket}): ${e.check} ${e.id} ${e.field} no longer differs by ${e.off} px: remove it or update it in KNOWN (cases.mjs)`);
}

try {
  const office = await loadOffice(mod);
  const proto = await openPrototype(opt("proto", DEFAULT_PROTO));
  const outDir = opt("out", flag("images") ? mkdtempSync(join(tmpdir(), "office-parity-out-")) : null);
  if (outDir) mkdirSync(outDir, { recursive: true });
  const report = { cases: [], palette: [] };
  try {
    report.palette = comparePalette(office.draw.PAL, paletteOf(proto.data.pal), office.crew.look);
    console.log(`== colours: ${report.palette.length} differ from the prototype's palette`);
    for (const f of report.palette) console.log(`    ${f.id}: office ${f.got}, prototype ${f.want}`);
    const chosen = CASES.filter((x) => !only || x.name === only);
    if (!chosen.length) throw new Error(`no case named ${only}; the cases are ${CASES.map((x) => x.name).join(", ")}`);
    for (const c of chosen) {
      const r = await drawOffice(office, { agents: c.crew, repos: c.repos, stage: c.stage });
      const res = await compareCase({ P: proto.data, r, c, crew: office.crew, proto, route: c.route ? ROUTE : null });
      const sorted = sortKnown(c.name, res.findings);
      print(c.name, r.k, res, sorted);
      report.cases.push({ name: c.name, k: r.k, counted: res.counted, findings: sorted.fresh, known: sorted.known, stale: sorted.stale });
      if (outDir) {
        const places = Object.fromEntries(r.L.people.filter((p) => !p.id.startsWith("x:")).map((p) => [p.id, { x: p.x, y: p.y }]));
        await makeImages(outDir, c.name, r, await proto.canvas(places), office.crew.look);
      }
    }
  } finally { proto.close(); }
  const bad = report.palette.length + report.cases.reduce((n, c) => n + c.findings.length + c.stale.length, 0);
  if (flag("json")) console.log(JSON.stringify(report));
  if (outDir) console.log(`\nimages (overlay: the prototype at 50% over the office; diff: where they differ): ${outDir}`);
  console.log(bad ? `\nFAIL: ${bad} differences` : `\nPASS: the office matches the prototype within 1 px, with identical colours${report.cases.some((c) => c.known.length) ? " (except the known differences listed above)" : ""}`);
  process.exit(bad ? 1 : 0);
} catch (e) {
  console.error("office-parity could not run: " + e.message);
  process.exit(2);
}
