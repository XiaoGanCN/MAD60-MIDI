#!/usr/bin/env python3
"""Sniff WebHID traffic from the FGG/MADLION web driver using Chrome DevTools Protocol.

Injects a hook at document-start that wraps navigator.hid + HIDDevice so every
sendReport / receiveFeatureReport / inputreport is logged as hex.

Usage:
  python3 tools/cdp_hid_sniff.py --out build/captures/hidlog.jsonl
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import time
import urllib.request

import websocket

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

HOOK = r"""
(() => {
  const log = [];
  window.__hidlog = log;
  const hex = (dv) => {
    try {
      const u8 = new Uint8Array(dv.buffer, dv.byteOffset, dv.byteLength);
      return Array.from(u8).map(b => b.toString(16).padStart(2, '0')).join(' ');
    } catch (e) { return 'ERR:' + e; }
  };
  const rec = (o) => { o.t = Date.now(); log.push(o); if (log.length > 50000) log.splice(0, 25000); };
  if (!navigator.hid) { rec({ dir: 'INIT', err: 'no navigator.hid' }); return; }
  const wrapDev = (d) => {
    if (!d || d.__wrapped) return d;
    try { d.__wrapped = true; } catch (e) { return d; }
    rec({ dir: 'DEV', info: {
      vendorId: d.vendorId, productId: d.productId, productName: d.productName,
      opened: d.opened,
      collections: (d.collections || []).map(c => ({ up: c.usagePage, u: c.usage, in: c.inputReports, out: c.outputReports, feat: c.featureReports }))
    }});
    try {
      const so = d.sendReport.bind(d);
      d.sendReport = (id, data) => { rec({ dir: 'TX', id: id, data: hex(data) }); return so(id, data); };
    } catch (e) { rec({ dir: 'ERR', where: 'sendReport', e: '' + e }); }
    try {
      const sf = d.sendFeatureReport.bind(d);
      d.sendFeatureReport = (id, data) => { rec({ dir: 'TXF', id: id, data: hex(data) }); return sf(id, data); };
    } catch (e) {}
    try {
      const rf = d.receiveFeatureReport.bind(d);
      d.receiveFeatureReport = (id) => rf(id).then(dv => {
        rec({ dir: 'RXF', id: id, data: hex(dv) }); return dv;
      });
    } catch (e) {}
    try {
      d.addEventListener('inputreport', (e) => { rec({ dir: 'RX', id: e.reportId, data: hex(e.data) }); });
    } catch (e) {}
    return d;
  };
  try {
    const origReq = navigator.hid.requestDevice.bind(navigator.hid);
    navigator.hid.requestDevice = (opts) => {
      rec({ dir: 'REQ', opts: JSON.stringify(opts && opts.filters) });
      return origReq(opts).then(ds => (ds || []).map(wrapDev));
    };
  } catch (e) { rec({ dir: 'ERR', where: 'requestDevice', e: '' + e }); }
  try {
    const origGet = navigator.hid.getDevices.bind(navigator.hid);
    navigator.hid.getDevices = () => origGet().then(ds => (ds || []).map(wrapDev));
  } catch (e) {}
  try { navigator.hid.addEventListener('connect', e => wrapDev(e.device)); } catch (e) {}
  rec({ dir: 'INIT', ok: true });
})();
"""


class CDP:
    def __init__(self, ws_url):
        self.ws = websocket.create_connection(ws_url, timeout=30, suppress_origin=True)
        self._id = 0
        self._lock = threading.Lock()
        self._pending = {}
        self._cv = threading.Condition()
        self._running = True
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        while self._running:
            try:
                msg = self.ws.recv()
            except Exception:
                break
            if not msg:
                continue
            try:
                m = json.loads(msg)
            except Exception:
                continue
            if "id" in m:
                with self._cv:
                    self._pending[m["id"]] = m
                    self._cv.notify_all()

    def call(self, method, params=None, session=None, timeout=25):
        with self._lock:
            self._id += 1
            mid = self._id
        msg = {"id": mid, "method": method}
        if params:
            msg["params"] = params
        if session:
            msg["sessionId"] = session
        self.ws.send(json.dumps(msg))
        end = time.time() + timeout
        with self._cv:
            while mid not in self._pending:
                rem = end - time.time()
                if rem <= 0:
                    raise TimeoutError(method)
                self._cv.wait(rem)
            return self._pending.pop(mid)

    def close(self):
        self._running = False
        try:
            self.ws.close()
        except Exception:
            pass


def http_json(base, path):
    with urllib.request.urlopen(base + path, timeout=10) as r:
        return json.load(r)


def wait_for_devtools(base, timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        try:
            return http_json(base, "/json/version")
        except Exception:
            time.sleep(0.4)
    raise TimeoutError("chrome devtools never came up")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9333)
    ap.add_argument("--url", default="https://hub.fgg.com.cn/")
    ap.add_argument("--profile", default="build/chrome-profile")
    ap.add_argument("--out", default="build/captures/hidlog.jsonl")
    ap.add_argument("--attach-only", action="store_true")
    ap.add_argument("--seconds", type=float, default=900)
    args = ap.parse_args()

    base = "http://127.0.0.1:%d" % args.port
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)

    ver = None
    try:
        ver = wait_for_devtools(base, 3)
        print("attaching to existing chrome on port %d" % args.port)
    except TimeoutError:
        if args.attach_only:
            print("no chrome on port %d" % args.port)
            return 1

    proc = None
    page_ws = None
    if ver is None:
        profile = os.path.abspath(args.profile)
        os.makedirs(profile, exist_ok=True)
        print("launching chrome (profile %s)" % profile)
        proc = subprocess.Popen(
            [CHROME,
             "--remote-debugging-port=%d" % args.port,
             "--remote-allow-origins=*",
             "--user-data-dir=" + profile,
             "--no-first-run", "--no-default-browser-check",
             "--disable-features=Translate",
             args.url],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True)
        ver = wait_for_devtools(base, 90)
        # wait for a page target
        end = time.time() + 60
        while time.time() < end:
            try:
                for t in http_json(base, "/json/list"):
                    if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
                        page_ws = t["webSocketDebuggerUrl"]
                        break
            except Exception:
                pass
            if page_ws:
                break
            time.sleep(0.5)
        if not page_ws:
            print("no page target found")
            return 1
    else:
        for t in http_json(base, "/json/list"):
            if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
                page_ws = t["webSocketDebuggerUrl"]
                break
        if not page_ws:
            print("no page target found"); return 1

    print("connecting to page target")
    cdp = CDP(page_ws)
    cdp.call("Page.enable", {})
    cdp.call("Runtime.enable", {})
    r = cdp.call("Page.addScriptToEvaluateOnNewDocument", {"source": HOOK})
    print("hook installed:", json.dumps(r.get("result", {})))
    cdp.call("Page.navigate", {"url": args.url})
    time.sleep(1.0)

    out = open(args.out, "a", buffering=1)
    print("logging to %s" % args.out)
    print(">>> In Chrome: click the connect/device button, pick 'MAD60', "
          "go to Performance > Calibration > Axial Alignment, then press keys. <<<")

    seen = 0
    end = time.time() + args.seconds
    while time.time() < end:
        time.sleep(1.5)
        try:
            res = cdp.call("Runtime.evaluate", {
                "expression": "JSON.stringify((window.__hidlog||[]))",
                "returnByValue": True,
            }, session=sid, timeout=15)
        except Exception as e:
            print("eval error:", e)
            continue
        val = res.get("result", {}).get("result", {}).get("value")
        if not val:
            continue
        try:
            entries = json.loads(val)
        except Exception:
            continue
        if len(entries) > seen:
            for e in entries[seen:]:
                out.write(json.dumps(e) + "\n")
            seen = len(entries)
            print("captured %d entries" % seen)
    out.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
