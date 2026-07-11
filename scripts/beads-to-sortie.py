#!/usr/bin/env python3
"""Puente Beads → Sortie (tracker file, solo-lectura).

Lee `bd list --json` (fuente de verdad: Beads) y escribe `.sortie/issues.json`
en el formato del file-based tracker de Sortie (docs/file-based-tasks-spec.md).
Sortie NUNCA escribe en este archivo; los cambios de estado los hace el agente
con `bd update/close`, y este script se re-ejecuta en cada ciclo de poll
(hook de Sortie o cron).
"""
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / ".sortie" / "issues.json"
JSONL = REPO / ".beads" / "issues.jsonl"


def load_beads() -> list:
    """bd list (fuente viva) con fallback al export JSONL versionado.

    En máquinas sin base de datos de Beads inicializada (p. ej. el Pi,
    despachador de solo-lectura), la fuente es el export .beads/issues.jsonl
    que viaja por git. Las escrituras de beads ocurren en máquinas con bd."""
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


def load_ready_ids() -> set | None:
    """IDs listos para trabajar según Beads (`bd ready` = sin bloqueos).

    Devuelve None si bd no está operativo (fallback JSONL): en ese caso
    se aplica la heurística conservadora dependency_count > 0 → blocked."""
    try:
        raw = subprocess.run(
            ["bd", "ready", "--json"],
            capture_output=True, text=True, cwd=REPO, check=True,
        ).stdout
        return {i["id"] for i in json.loads(raw or "[]")}
    except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError):
        return None


def effective_state(b: dict, ready: set | None) -> str:
    """Estado para Sortie respetando el ready-queue de Beads (review Codex P1).

    Un bead `open` bloqueado por dependencias no debe despacharse: se exporta
    como `blocked` (fuera de active_states). Con bd vivo la verdad es `bd ready`;
    en fallback JSONL, dependency_count > 0 bloquea por precaución."""
    state = b.get("status", "open")
    if state != "open":
        return state
    if ready is not None:
        return "open" if b["id"] in ready else "blocked"
    return "blocked" if b.get("dependency_count", 0) > 0 else "open"


def main() -> int:
    beads = load_beads()
    ready = load_ready_ids()

    issues = []
    for b in beads:
        issues.append({
            "id": b["id"],
            "identifier": b["id"],
            "title": b["title"],
            "state": effective_state(b, ready),
            "description": b.get("description", ""),
            "priority": b.get("priority"),
            "assignee": b.get("assignee", ""),
            "issue_type": b.get("issue_type", ""),
            "labels": b.get("labels", []) or [],
            "created_at": b.get("created_at", ""),
            "updated_at": b.get("updated_at", ""),
        })

    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps(issues, ensure_ascii=False, indent=2) + "\n")
    print(f"{len(issues)} issues → {OUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
