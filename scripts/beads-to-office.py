#!/usr/bin/env python3
"""Pegamento Beads → My Virtual Office (bead TripSquad-iOS-pms).

Publica el estado de los beads en la oficina pixel del Pi para que deje de ser
animación y muestre la verdad de la fábrica:

1. **Kanban** — proyecto "TripSquad — Beads" (API `/api/projects`): una tarea
   por bead, en la columna que corresponde a su estado. Persistente.
2. **Presencia** — el agente de la oficina (`/api/presence/<id>`) aparece
   `working` con el bead in_progress como tarea. El override manual de la
   oficina expira a los ~30 s, por eso el modo `--loop` re-publica cada ciclo.

Solo lectura sobre Beads (misma fuente y fallback que scripts/beads-to-sortie.py):
`bd list --json` si hay DB, si no el export versionado `.beads/issues.jsonl`.
La API de la oficina se documentó leyendo el server real en el contenedor
(`/app/server.py` de ghcr.io/eliautobot/my-virtual-office) — no hay doc pública.

Uso:
  beads-to-office.py            # un ciclo de sync
  beads-to-office.py --loop 20  # bucle cada 20 s (systemd); git pull cada PULL_EVERY ciclos
  beads-to-office.py --smoke    # smoke test end-to-end (crea y borra una tarea SMOKE)

Env: VO_URL (default http://127.0.0.1:8090) · VO_PRESENCE_AGENT (default
claude-code-main) · VO_PROJECT_TITLE (default "TripSquad — Beads") ·
PULL_EVERY (default 15 ciclos).
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(os.environ.get("BEADS_REPO", Path(__file__).resolve().parent.parent))
JSONL = REPO / ".beads" / "issues.jsonl"

VO_URL = os.environ.get("VO_URL", "http://127.0.0.1:8090").rstrip("/")
PRESENCE_AGENT = os.environ.get("VO_PRESENCE_AGENT", "claude-code-main")
PROJECT_TITLE = os.environ.get("VO_PROJECT_TITLE", "TripSquad — Beads")
PULL_EVERY = int(os.environ.get("PULL_EVERY", "15"))
# auto = bd si está operativo, si no JSONL · jsonl = SOLO el export versionado
BEADS_SOURCE = os.environ.get("BEADS_SOURCE", "auto")
STALE_WARN_H = float(os.environ.get("STALE_WARN_H", "24"))  # aviso de export rancio
STATE_FILE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "vo-beads-sync.json"

# estado efectivo del bead → columna del kanban ("Review" queda para movimientos
# manuales/futuros: Beads no distingue review hoy)
COLUMN_BY_STATE = {
    "ready": "Ready",
    "in_progress": "In Progress",
    "blocked": "Blocked",
    "closed": "Done",
}
COLUMNS = [
    {"title": "Ready", "color": "#6c757d"},
    {"title": "In Progress", "color": "#ffc107"},
    {"title": "Review", "color": "#fd7e14"},
    {"title": "Blocked", "color": "#dc3545"},
    {"title": "Done", "color": "#198754"},
]
PRIORITY = {0: "high", 1: "high", 2: "medium"}  # resto → low


# ─── Beads (idéntico contrato que beads-to-sortie.py) ───────────────────────

def jsonl_age_hours() -> float:
    """Antigüedad del export según el último commit que lo tocó.

    El JSONL es un export PASIVO: solo se refresca cuando alguien corre
    `bd export` y lo commitea. Si nadie lo hace, el kanban publica datos
    rancios en silencio (review Codex P2, PR #7). Aquí no se puede arreglar
    solo (el Pi no tiene DB de beads: `bd` responde "no beads database
    found"), así que la mitigación honesta es MEDIRLO y avisar."""
    try:
        ts = subprocess.run(
            ["git", "log", "-1", "--format=%ct", "--", str(JSONL)],
            capture_output=True, text=True, cwd=REPO, check=True,
        ).stdout.strip()
        return (time.time() - int(ts)) / 3600 if ts else -1.0
    except (subprocess.CalledProcessError, FileNotFoundError, ValueError):
        return -1.0


def load_beads() -> list:
    if BEADS_SOURCE == "jsonl":
        # Fuente forzada para el servicio del Pi: es su ÚNICA fuente real
        # (no hay DB de beads allí) y la refresca `git pull` en cada ciclo.
        if not JSONL.exists():
            raise SystemExit("BEADS_SOURCE=jsonl pero no existe .beads/issues.jsonl")
        age = jsonl_age_hours()
        if age > STALE_WARN_H:
            print(f"⚠️  export de beads con {age:.1f} h de antigüedad "
                  f"(>{STALE_WARN_H} h): alguien debe correr `bd export -o "
                  f".beads/issues.jsonl` y commitearlo, o el kanban miente",
                  file=sys.stderr, flush=True)
        rows = [json.loads(l) for l in JSONL.read_text().splitlines() if l.strip()]
        return [r for r in rows if r.get("_type") in (None, "issue")]
    try:
        raw = subprocess.run(
            ["bd", "list", "--json", "--status", "open,in_progress,blocked,closed"],
            capture_output=True, text=True, cwd=REPO, check=True,
        ).stdout
        return json.loads(raw or "[]")
    except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError):
        if not JSONL.exists():
            raise SystemExit("ni bd operativo ni .beads/issues.jsonl — sin fuente de beads")
        rows = [json.loads(l) for l in JSONL.read_text().splitlines() if l.strip()]
        return [r for r in rows if r.get("_type") in (None, "issue")]


def load_ready_ids():
    if BEADS_SOURCE == "jsonl":
        return None  # heurística dependency_count, coherente con la fuente JSONL
    try:
        raw = subprocess.run(
            ["bd", "ready", "--json"], capture_output=True, text=True, cwd=REPO, check=True,
        ).stdout
        return {i["id"] for i in json.loads(raw or "[]")}
    except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError):
        return None


def effective_state(b: dict, ready) -> str:
    state = b.get("status", "open")
    if state in ("in_progress", "blocked", "closed"):
        return state
    if ready is not None:
        return "ready" if b["id"] in ready else "blocked"
    return "blocked" if b.get("dependency_count", 0) > 0 else "ready"


# ─── Cliente HTTP de la oficina (stdlib, sin dependencias) ───────────────────

def vo(method: str, path: str, body=None):
    req = urllib.request.Request(
        f"{VO_URL}{path}",
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            payload = r.read().decode() or "{}"
            return json.loads(payload)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path} → HTTP {e.code}: {e.read().decode()[:200]}")
    except (urllib.error.URLError, TimeoutError) as e:
        raise RuntimeError(f"{method} {path} → oficina inaccesible: {e}")


def ensure_project() -> dict:
    """Devuelve el proyecto COMPLETO (el listado viene sin `tasks`; sin el
    objeto completo el matching fallaría y cada ciclo duplicaría tareas)."""
    projects = vo("GET", "/api/projects").get("projects", [])
    for p in projects:
        if p.get("title") == PROJECT_TITLE:
            full = vo("GET", f"/api/projects/{p['id']}")
            return full.get("project", full)
    import uuid
    created = vo("POST", "/api/projects", {
        "title": PROJECT_TITLE,
        "description": "Espejo de solo-lectura del tracker Beads (scripts/beads-to-office.py). "
                       "La verdad vive en bd; los cambios aquí NO vuelven a Beads.",
        "createdBy": "beads-to-office",
        # ids generados aquí: el server conserva las columnas tal cual llegan
        "columns": [{"id": uuid.uuid4().hex[:8], "title": c["title"],
                     "color": c["color"], "order": i}
                    for i, c in enumerate(COLUMNS)],
    })
    return created["project"]


def sync_kanban(project: dict, beads: list, states: dict) -> dict:
    """Upsert de una tarea por bead, etiquetada bead:<id> para el matching."""
    col_id = {c["title"]: c["id"] for c in project.get("columns", [])}
    by_tag = {}
    for t in project.get("tasks", []):
        for tag in t.get("tags", []):
            if tag.startswith("bead:"):
                by_tag[tag[5:]] = t
    counts = {"created": 0, "moved": 0, "unchanged": 0}
    for b in beads:
        state = states[b["id"]]
        target_col = col_id.get(COLUMN_BY_STATE[state])
        if not target_col:
            continue
        title = f"{b['id']} — {b.get('title', '')}"[:120]
        prio = PRIORITY.get(b.get("priority", 2), "low")
        task = by_tag.get(b["id"])
        if task is None:
            vo("POST", f"/api/projects/{project['id']}/tasks", {
                "title": title, "columnId": target_col, "priority": prio,
                "tags": [f"bead:{b['id']}", f"P{b.get('priority', '?')}"],
                "description": (b.get("description") or "")[:400],
            })
            counts["created"] += 1
        elif task.get("columnId") != target_col or task.get("title") != title:
            vo("PUT", f"/api/projects/{project['id']}/tasks/{task['id']}", {
                "columnId": target_col, "title": title, "priority": prio,
                "by": "beads-to-office",
            })
            counts["moved"] += 1
        else:
            counts["unchanged"] += 1
    return counts


def sync_presence(beads: list, states: dict) -> str:
    """El muñeco trabaja si hay beads in_progress; idle solo en la transición
    (el override expira solo — no hace falta machacar idle cada ciclo)."""
    working = [b for b in beads if states[b["id"]] == "in_progress"]
    prev = {}
    if STATE_FILE.exists():
        try:
            prev = json.loads(STATE_FILE.read_text())
        except json.JSONDecodeError:
            prev = {}
    if working:
        task = " · ".join(f"{b['id']} {b.get('title', '')}"[:60] for b in working[:2])
        vo("POST", f"/api/presence/{PRESENCE_AGENT}", {"state": "working", "task": task})
        now_state = "working"
    else:
        now_state = "idle"
        if prev.get("state") != "idle":
            vo("POST", f"/api/presence/{PRESENCE_AGENT}", {"state": "idle"})
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps({"state": now_state, "ts": time.time()}))
    return now_state


def one_cycle() -> str:
    beads = load_beads()
    ready = load_ready_ids()
    states = {b["id"]: effective_state(b, ready) for b in beads}
    project = ensure_project()
    counts = sync_kanban(project, beads, states)
    presence = sync_presence(beads, states)
    return (f"beads={len(beads)} kanban(+{counts['created']} →{counts['moved']} "
            f"={counts['unchanged']}) presence={presence}")


def smoke() -> int:
    """Smoke test end-to-end: oficina viva, proyecto operable, tarea de ida y vuelta."""
    ok = True

    def check(name, fn):
        nonlocal ok
        try:
            fn()
            print(f"  ✅ {name}")
        except Exception as e:
            ok = False
            print(f"  ❌ {name}: {e}")

    print(f"SMOKE beads-to-office → {VO_URL}")
    check("health", lambda: vo("GET", "/health"))
    check("api/agents responde", lambda: vo("GET", "/api/agents")["agents"])
    check("fuente de beads legible", lambda: load_beads())

    project = {}
    check("proyecto kanban existe/creable", lambda: project.update(ensure_project()))
    if project:
        col = project["columns"][0]["id"]
        created = {}
        check("crear tarea SMOKE", lambda: created.update(
            vo("POST", f"/api/projects/{project['id']}/tasks",
               {"title": "SMOKE beads-to-office (borrar)", "columnId": col,
                "tags": ["smoke"]})["task"]))
        if created:
            check("borrar tarea SMOKE", lambda: vo(
                "DELETE", f"/api/projects/{project['id']}/tasks/{created['id']}"))
    print("SMOKE:", "OK" if ok else "FALLO")
    return 0 if ok else 1


def main() -> int:
    args = sys.argv[1:]
    if "--smoke" in args:
        return smoke()
    if "--loop" in args:
        interval = int(args[args.index("--loop") + 1]) if len(args) > args.index("--loop") + 1 else 20
        cycle = 0
        while True:
            if cycle % max(PULL_EVERY, 1) == 0:
                subprocess.run(["git", "pull", "--ff-only", "--quiet"], cwd=REPO,
                               capture_output=True)
            try:
                print(one_cycle(), flush=True)
            except Exception as e:
                print(f"ciclo con error (se reintenta): {e}", file=sys.stderr, flush=True)
            cycle += 1
            time.sleep(interval)
    print(one_cycle())
    return 0


if __name__ == "__main__":
    sys.exit(main())
