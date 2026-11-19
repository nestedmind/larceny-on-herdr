// A headless Chrome driven over its remote-debugging port with node's own WebSocket: nothing to install.
// Used to read the prototype, to analyse a shot of the live window, and to make the overlay and diff images.

import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, appendFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export const CHROME = process.env.PARITY_CHROME || "/usr/bin/google-chrome";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Every Chrome this process started and has not yet ended. Each runs as its own process group (its pid is the group id),
// so ending the group ends its helpers and pipes too. Only these groups are ever signalled, never a match by name.
const live = new Set();

function groupAlive(pgid) {
  const r = spawnSync("ps", ["-eo", "pgid=,stat="], { encoding: "utf8" });
  return String(r.stdout).split("\n").some((l) => { const [g, st] = l.trim().split(/\s+/); return Number(g) === pgid && !st.startsWith("Z"); });
}

function endGroup(proc, dir) {
  try { process.kill(-proc.pid, "SIGKILL"); } catch (_) { /* already gone */ }
  // Wait (up to 3 s) until no live member of the group is left (a zombie, such as the leader before node reaps it, is
  // not live), so nothing is still writing into the folder when it is removed.
  for (let i = 0; i < 100 && groupAlive(proc.pid); i++) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 30);
  for (let i = 0; i < 5; i++) {
    try { rmSync(dir, { recursive: true, force: true }); } catch (_) { /* a dying Chrome may still write */ }
    if (!existsSync(dir)) break;
  }
  try { rmSync(tmps.get(proc), { recursive: true, force: true }); } catch (_) { /* gone */ }
  live.delete(proc);
}
const dirs = new Map();
const tmps = new Map();
const endAll = () => { for (const p of [...live]) endGroup(p, dirs.get(p)); };
process.on("exit", endAll);
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(sig, () => { endAll(); process.exit(128 + ({ SIGHUP: 1, SIGINT: 2, SIGTERM: 15 })[sig]); });

export class Chrome {
  static async launch({ width = 1600, height = 1000, before = "" } = {}) {
    const dir = mkdtempSync(join(process.env.PARITY_TMP || tmpdir(), "parity-chrome-"));
    // Chrome's own temp files (its socket path must stay under 108 characters, so this is a short folder, not under the profile).
    const ctmp = mkdtempSync(join(tmpdir(), "pct-"));
    const proc = spawn(CHROME, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${dir}`, "--no-first-run", "--disable-gpu",
      "--hide-scrollbars", "--no-proxy-server", "--force-device-scale-factor=1", `--window-size=${width},${height}`, "about:blank"], { stdio: "ignore", detached: true, env: { ...process.env, TMPDIR: ctmp } });
    live.add(proc); dirs.set(proc, dir); tmps.set(proc, ctmp);
    if (process.env.PARITY_PIDS) appendFileSync(process.env.PARITY_PIDS, proc.pid + "\n");
    const portFile = join(dir, "DevToolsActivePort");
    try {
    for (let i = 0; i < 100 && !existsSync(portFile); i++) await sleep(100);
    if (!existsSync(portFile)) { throw new Error(`${CHROME} did not open a debugging port`); }
    const port = readFileSync(portFile, "utf8").split("\n")[0];
    let target;
    for (let i = 0; i < 50 && !target; i++) {
      try { target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === "page"); } catch (_) { /* not up yet */ }
      if (!target) await sleep(100);
    }
    const ws = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((ok, no) => { ws.onopen = ok; ws.onerror = () => no(new Error("could not connect to Chrome")); });
    const c = new Chrome(proc, ws, dir);
    await c.send("Page.enable");
    if (before) await c.send("Page.addScriptToEvaluateOnNewDocument", { source: before });
    return c;
    } catch (e) { endGroup(proc, dir); throw e; }
  }

  constructor(proc, ws, dir) {
    this.proc = proc; this.ws = ws; this.dir = dir; this.id = 0; this.waiting = new Map(); this.events = [];
    ws.onmessage = (m) => {
      const msg = JSON.parse(m.data);
      if (msg.id && this.waiting.has(msg.id)) { const [ok, no] = this.waiting.get(msg.id); this.waiting.delete(msg.id); msg.error ? no(new Error(msg.error.message)) : ok(msg.result); }
      else if (msg.method) this.events.push(msg.method);
    };
  }

  send(method, params = {}) {
    return new Promise((ok, no) => { const id = ++this.id; this.waiting.set(id, [ok, no]); this.ws.send(JSON.stringify({ id, method, params })); });
  }

  async open(url) {
    this.events.length = 0;
    await this.send("Page.navigate", { url });
    for (let i = 0; i < 200 && !this.events.includes("Page.loadEventFired"); i++) await sleep(50);
  }

  /** Runs an expression (a promise is awaited) and gives its value. */
  async eval(expression) {
    const r = await this.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error("in the page: " + ((r.exceptionDetails.exception && r.exceptionDetails.exception.description) || r.exceptionDetails.text));
    return r.result.value;
  }

  /** The page as a PNG file, `width` by `height` px (device pixels equal CSS pixels). */
  async shot(file, width, height) {
    await this.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false });
    const r = await this.send("Page.captureScreenshot", { format: "png", clip: { x: 0, y: 0, width, height, scale: 1 } });
    writeFileSync(file, Buffer.from(r.data, "base64"));
  }

  close() {
    try { this.ws.close(); } catch (_) { /* gone */ }
    endGroup(this.proc, this.dir);
  }
}
