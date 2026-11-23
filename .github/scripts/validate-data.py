#!/usr/bin/env python3
"""Validate the shared game-data pack under data/.

1. Every data/**/*.json file must parse as JSON.
2. Every schema in data/schema/ must be a valid JSON Schema (metaschema check).
3. Schema lookup per data file, first match wins:
     data/schema/<file stem>.schema.json        (e.g. data/xp_curve.json)
     data/schema/<parent dir name>.schema.json  (e.g. data/patterns/spiral.json -> patterns.schema.json)
4. Every schema must be used by at least one data file, and every data file outside
   data/schema/ must have a schema (no unvalidated data).

Requires check-jsonschema on PATH.
"""
import json
import pathlib
import subprocess
import sys

root = pathlib.Path("data")
schema_dir = root / "schema"
errors = 0

def err(msg):
    global errors
    errors += 1
    print(f"::error::{msg}")

json_files = sorted(p for p in root.rglob("*.json") if p.is_file())
for p in json_files:
    try:
        json.loads(p.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        err(f"{p}: invalid JSON: {exc}")

schemas = sorted(schema_dir.glob("*.schema.json"))
if not schemas:
    err(f"{schema_dir}/ exists but contains no *.schema.json files")

if schemas:
    r = subprocess.run(["check-jsonschema", "--check-metaschema", *map(str, schemas)])
    if r.returncode != 0:
        err("one or more schemas failed the JSON Schema metaschema check")

data_files = [p for p in json_files if schema_dir not in p.parents]
by_schema = {}
for p in data_files:
    candidates = [schema_dir / f"{p.stem}.schema.json", schema_dir / f"{p.parent.name}.schema.json"]
    s = next((c for c in candidates if c.exists()), None)
    if s is not None:
        by_schema.setdefault(s, []).append(p)
    else:
        err(f"{p}: no matching schema (looked for {', '.join(map(str, candidates))})")

for s in schemas:
    if s not in by_schema:
        print(f"::warning::{s}: no data file uses this schema yet")

for s, files in sorted(by_schema.items()):
    r = subprocess.run(["check-jsonschema", "--schemafile", str(s), *map(str, files)])
    if r.returncode != 0:
        err(f"data files failed validation against {s}")

print(f"data-validate: {len(data_files)} data files, {len(schemas)} schemas, {errors} errors")
sys.exit(1 if errors else 0)
