#!/usr/bin/env python3
"""my_claude dashboard: local status page for the LiteLLM proxy and claude sessions.

Started by `my_claude --dashboard`. Needs MY_CLAUDE_KEY, MY_CLAUDE_PORT and
MY_CLAUDE_DASH_PORT in the environment. Open the URL it prints (includes the key).
"""

import asyncio
import hmac
import os
import re
import subprocess
import time
from datetime import datetime, timezone

import httpx
import uvicorn
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse

app = FastAPI(title="my_claude dashboard")


def require_key(request: Request) -> None:
    supplied = request.query_params.get("key") or request.headers.get("x-key", "")
    if not hmac.compare_digest(supplied, LITELLM_KEY):
        raise HTTPException(status_code=401, detail="missing or wrong key")


PORT = int(os.environ.get("MY_CLAUDE_PORT", "4141"))
DASH_PORT = int(os.environ.get("MY_CLAUDE_DASH_PORT", str(PORT + 1)))
LITELLM_URL = f"http://127.0.0.1:{PORT}"
LITELLM_KEY = os.environ["MY_CLAUDE_KEY"]
BOOT_TIME = time.time()


# ── helpers ──────────────────────────────────────────────────────────────────

async def litellm_health() -> dict:
    try:
        async with httpx.AsyncClient(timeout=3) as c:
            r = await c.get(f"{LITELLM_URL}/health/readiness")
            data = r.json()
            return {"status": "healthy", "version": data.get("litellm_version", "?"), "raw": data}
    except Exception as e:
        return {"status": "down", "error": str(e)}


async def litellm_models() -> list[str]:
    try:
        async with httpx.AsyncClient(timeout=3) as c:
            r = await c.get(f"{LITELLM_URL}/v1/models",
                            headers={"Authorization": f"Bearer {LITELLM_KEY}"})
            data = r.json()
            return [m["id"] for m in data.get("data", [])]
    except Exception:
        return []


def machine_info() -> dict:
    info: dict = {}
    # Load averages
    try:
        with open("/proc/loadavg") as f:
            parts = f.read().split()
            info["load_1m"], info["load_5m"], info["load_15m"] = parts[0], parts[1], parts[2]
    except Exception:
        pass
    # Memory
    try:
        with open("/proc/meminfo") as f:
            mem = {}
            for line in f:
                k, *v = line.split()
                mem[k.rstrip(":")] = int(v[0]) if v else 0
            total = mem.get("MemTotal", 1)
            avail = mem.get("MemAvailable", 0)
            used = total - avail
            info["mem_total_gb"] = round(total / 1048576, 1)
            info["mem_used_gb"] = round(used / 1048576, 1)
            info["mem_pct"] = round(100 * used / total, 1)
    except Exception:
        pass
    # CPU count
    try:
        info["cpus"] = os.cpu_count() or 0
    except Exception:
        pass
    return info


def claude_sessions() -> list[dict]:
    """Count running claude processes (no command lines are exposed)."""
    sessions = []
    my_uid = os.getuid()
    try:
        out = subprocess.check_output(
            ["ps", "-eo", "pid,uid,etime,args", "--no-headers"],
            text=True, timeout=5
        )
        for line in out.strip().splitlines():
            parts = line.split(None, 3)
            if len(parts) < 4:
                continue
            pid, uid, etime, cmd = parts
            if int(uid) != my_uid:
                continue
            if "claude" in cmd.lower():
                # skip dashboard, grep artifacts, and other non-session processes
                if "dashboard.py" in cmd or "python" in cmd.split()[0].lower():
                    continue
                sessions.append({
                    "pid": int(pid),
                    "elapsed": etime,
                    "command": "claude",
                })
    except Exception:
        pass
    return sessions


def litellm_process() -> dict | None:
    """Find the running LiteLLM proxy process."""
    my_uid = os.getuid()
    try:
        out = subprocess.check_output(
            ["ps", "-eo", "pid,uid,etime,args", "--no-headers"],
            text=True, timeout=5
        )
        for line in out.strip().splitlines():
            parts = line.split(None, 3)
            if len(parts) < 4:
                continue
            pid, uid, etime, cmd = parts
            if int(uid) != my_uid:
                continue
            if "litellm" in cmd and "config.yaml" in cmd and "grep" not in cmd:
                return {"pid": int(pid), "elapsed": etime, "command": "litellm"}
    except Exception:
        pass
    return None


# ── API ──────────────────────────────────────────────────────────────────────

@app.get("/api/status", dependencies=[Depends(require_key)])
async def api_status():
    health, models = await asyncio.gather(litellm_health(), litellm_models())
    return JSONResponse({
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "litellm": {**health, "process": litellm_process(), "models": models},
        "claude_sessions": claude_sessions(),
        "machine": machine_info(),
        "port": PORT,
        "dashboard_uptime_s": round(time.time() - BOOT_TIME),
    })


# ── HTML Dashboard ───────────────────────────────────────────────────────────

DASHBOARD_HTML = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Claude Dashboard</title>
<style>
  :root { --bg: #0d1117; --card: #161b22; --border: #30363d; --text: #e6edf3;
          --dim: #8b949e; --green: #3fb950; --red: #f85149; --blue: #58a6ff;
          --yellow: #d29922; }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, 'Segoe UI', monospace; background: var(--bg);
         color: var(--text); padding: 20px; }
  h1 { font-size: 1.4rem; margin-bottom: 16px; color: var(--blue); }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(380px, 1fr));
          gap: 16px; }
  .card { background: var(--card); border: 1px solid var(--border); border-radius: 8px;
          padding: 16px; }
  .card h2 { font-size: 0.95rem; color: var(--dim); margin-bottom: 10px;
             text-transform: uppercase; letter-spacing: 1px; }
  .status { display: inline-block; padding: 2px 10px; border-radius: 12px;
            font-size: 0.85rem; font-weight: 600; }
  .status.healthy { background: #0d2818; color: var(--green); }
  .status.down { background: #2d1215; color: var(--red); }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
  td, th { padding: 4px 8px; text-align: left; border-bottom: 1px solid var(--border); }
  th { color: var(--dim); font-weight: 500; }
  .val { color: var(--blue); font-weight: 600; }
  .model-tag { display: inline-block; background: #1a2332; color: var(--blue);
               padding: 2px 8px; border-radius: 4px; margin: 2px; font-size: 0.8rem; }
  .session { background: #1a1e24; border: 1px solid var(--border); border-radius: 6px;
             padding: 8px 12px; margin-bottom: 6px; font-size: 0.85rem; }
  .session .pid { color: var(--yellow); font-weight: 600; }
  .session .elapsed { color: var(--dim); }
  .session .cmd { color: var(--text); word-break: break-all; }
  .bar-bg { background: var(--border); border-radius: 4px; height: 8px; margin-top: 4px; }
  .bar-fill { height: 8px; border-radius: 4px; background: var(--blue); }
  .updated { color: var(--dim); font-size: 0.75rem; margin-top: 16px; text-align: center; }
  .none { color: var(--dim); font-style: italic; }
</style>
</head>
<body>
<h1>Claude Code Dashboard</h1>
<div class="grid" id="dashboard">
  <div class="card"><h2>Loading...</h2></div>
</div>
<div class="updated" id="updated"></div>
<script>
async function refresh() {
  try {
    const r = await fetch('/api/status' + location.search);
    const d = await r.json();
    const grid = document.getElementById('dashboard');
    const ll = d.litellm;
    const m = d.machine;
    const sessions = d.claude_sessions;

    let modelsHtml = (ll.models || []).map(m => `<span class="model-tag">${m}</span>`).join('') || '<span class="none">unavailable</span>';

    let sessionsHtml = '';
    if (sessions.length === 0) {
      sessionsHtml = '<div class="none">No active Claude sessions</div>';
    } else {
      sessionsHtml = sessions.map(s =>
        `<div class="session">
           <span class="pid">PID ${s.pid}</span>
           <span class="elapsed">${s.elapsed}</span><br>
           <span class="cmd">${s.command}</span>
         </div>`
      ).join('');
    }

    let proxyProc = ll.process
      ? `PID <span class="val">${ll.process.pid}</span> &middot; uptime ${ll.process.elapsed}`
      : '<span class="none">not found</span>';

    let memBar = m.mem_pct
      ? `<div class="bar-bg"><div class="bar-fill" style="width:${m.mem_pct}%"></div></div>`
      : '';

    grid.innerHTML = `
      <div class="card">
        <h2>LiteLLM Proxy</h2>
        <table>
          <tr><td>Status</td><td><span class="status ${ll.status}">${ll.status}</span></td></tr>
          <tr><td>Version</td><td class="val">${ll.version || '-'}</td></tr>
          <tr><td>Process</td><td>${proxyProc}</td></tr>
          <tr><td>Endpoint</td><td class="val">127.0.0.1:${d.port}</td></tr>
        </table>
      </div>
      <div class="card">
        <h2>Machine</h2>
        <table>
          <tr><td>CPUs</td><td class="val">${m.cpus}</td></tr>
          <tr><td>Load</td><td class="val">${m.load_1m} / ${m.load_5m} / ${m.load_15m}</td></tr>
          <tr><td>Memory</td><td class="val">${m.mem_used_gb} / ${m.mem_total_gb} GB (${m.mem_pct}%)</td></tr>
        </table>
        ${memBar}
      </div>
      <div class="card">
        <h2>Claude Sessions (${sessions.length})</h2>
        ${sessionsHtml}
      </div>
      <div class="card">
        <h2>Available Models (${(ll.models||[]).length})</h2>
        ${modelsHtml}
      </div>
    `;

    document.getElementById('updated').textContent =
      'Last updated: ' + new Date(d.timestamp).toLocaleTimeString() +
      ' · Dashboard uptime: ' + Math.floor(d.dashboard_uptime_s / 60) + 'm';
  } catch (e) {
    document.getElementById('updated').textContent = 'Error: ' + e.message;
  }
}
refresh();
setInterval(refresh, 10000);
</script>
</body>
</html>
"""


@app.get("/", response_class=HTMLResponse, dependencies=[Depends(require_key)])
async def index():
    return DASHBOARD_HTML


# ── main ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=DASH_PORT, log_level="warning")
