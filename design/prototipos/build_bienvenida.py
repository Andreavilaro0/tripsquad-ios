#!/usr/bin/env python3
# Genera tripsquad-bienvenida.html inyectando las 5 escenas (base64 jpeg) en el CSS.
import pathlib

BASE = pathlib.Path(__file__).parent
out = (BASE / "tripsquad-bienvenida.template.html").read_text()
for i, name in enumerate(["S1-mesa", "S2-reparto", "S3-votacion", "S4-camino", "S5-recuerdos"], 1):
    b64 = (BASE / "insp2" / f"{name}.jpg.b64").read_text().replace("\n", "").strip()
    out = out.replace(f"__S{i}__", b64)
for i, name in enumerate(["S1-mesa", "S2-reparto", "S3-votacion", "S4-camino", "S5-recuerdos"], 1):
    vid = (BASE / "insp2" / f"{name}-loop.webp.b64").read_text().replace("\n", "").strip()
    out = out.replace(f"__S{i}VID__", vid)
(BASE / "tripsquad-bienvenida.html").write_text(out)
print("OK", len(out) // 1024, "KB")
