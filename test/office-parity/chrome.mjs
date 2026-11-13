// A headless Chrome driven over its remote-debugging port with node's own WebSocket: nothing to install.
// Used to read the prototype, to analyse a shot of the live window, and to make the overlay and diff images.

import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export const CHROME = process.env.PARITY_CHROME || "/usr/bin/google-chrome";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export class Chrome {
  static async launch({ width = 1600, height = 1000, before = "" } = {}) {
    const dir = mkdtempSync(join(tmpdir(), "parity-chrome-"));
    const proc = spawn(CHROME, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${dir}`, "--no-first-run", "--disable-gpu",
      "--hide-scrollbars", "--no-proxy-server", "--force-device-scale-factor=1", `--window-size=${width},${height}`, "about:blank"], { stdio: "ignore" });
    const portFile = join(dir, "DevToolsActivePort");
    for (let i = 0; i < 100 && !existsSync(portFile); i++) await sleep(100);
    if (!existsSync(portFile)) { proc.kill(); throw new Error(`${CHROME} did not open a debugging port`); }
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
    this.proc.kill();
    try { rmSync(this.dir, { recursive: true, force: true }); } catch (_) { /* Chrome may still hold it */ }
  }
}
