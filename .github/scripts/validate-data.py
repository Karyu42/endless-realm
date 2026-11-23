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

# --- content-v0.1 §5: pattern references and damage_key ---
enemies_path = root / "enemies.json"
patterns_path = root / "patterns.json"
if enemies_path.exists() and patterns_path.exists():
    enemies_doc = json.loads(enemies_path.read_text(encoding="utf-8"))
    patterns_doc = json.loads(patterns_path.read_text(encoding="utf-8"))
    pattern_ids = {
        str(p.get("id"))
        for p in patterns_doc.get("patterns", [])
        if isinstance(p, dict) and p.get("id")
    }
    patterns_by_id = {
        str(p.get("id")): p
        for p in patterns_doc.get("patterns", [])
        if isinstance(p, dict) and p.get("id")
    }

    def pattern_refs(obj, acc, path=""):
        if isinstance(obj, dict):
            fire = obj.get("fire")
            if isinstance(fire, str) and fire:
                acc.append((f"{path}.fire" if path else "fire", fire))
            for key in ("pattern", "pattern_id"):
                val = obj.get(key)
                if isinstance(val, str) and val:
                    acc.append((f"{path}.{key}" if path else key, val))
            child = obj.get("child")
            if isinstance(child, str) and child:
                acc.append((f"{path}.child" if path else "child", child))
            for k, v in obj.items():
                if k in ("pattern", "pattern_id", "fire", "child") and isinstance(v, str):
                    continue
                pattern_refs(v, acc, f"{path}.{k}" if path else k)
        elif isinstance(obj, list):
            for i, v in enumerate(obj):
                pattern_refs(v, acc, f"{path}[{i}]")

    for i, enemy in enumerate(enemies_doc.get("enemies", [])):
        if not isinstance(enemy, dict):
            continue
        eid = str(enemy.get("id", f"enemies[{i}]"))
        refs = []
        pattern_refs(enemy, refs, eid)
        damage = {}
        base = enemy.get("base", {})
        if isinstance(base, dict) and isinstance(base.get("damage"), dict):
            damage = {str(k): v for k, v in base["damage"].items()}
        used_keys = set()
        for loc, pid in refs:
            if pid not in pattern_ids:
                err(f"{loc}: pattern reference {pid!r} is not in patterns.json")
                continue
            key = str(patterns_by_id[pid].get("damage_key") or "")
            if not key:
                continue
            used_keys.add(key)
            if key not in damage:
                err(
                    f"{eid}: pattern {pid!r} damage_key {key!r} is missing from base.damage"
                )
        for key in sorted(damage):
            if key not in used_keys:
                print(f"::warning::{eid}: unused damage_key {key!r} in base.damage")

# --- content-v0.1 §5: loot weight sums ---
loot_path = root / "loot.json"
if loot_path.exists():
    loot = json.loads(loot_path.read_text(encoding="utf-8"))

    def sum_ok(name, values, expect=100):
        total = sum(int(v) for v in values)
        if total != expect:
            err(f"{name} weights sum to {total}, expected {expect}")

    for row_name, row in (loot.get("tier_rows") or {}).items():
        if isinstance(row, list):
            sum_ok(f"loot.json tier_rows.{row_name}", [e.get("w", 0) for e in row if isinstance(e, dict)])
    sw = loot.get("slot_weights") or {}
    if sw:
        sum_ok("loot.json slot_weights", [sw.get("weapon", 0), sw.get("armor", 0), sw.get("charm", 0)])
    ww = loot.get("weapon_class_weights") or {}
    if ww:
        # own + 2 × other_each (three classes)
        total = int(ww.get("own", 0)) + 2 * int(ww.get("other_each", 0))
        if total != 100:
            err(f"loot.json weapon_class_weights own + 2×other_each = {total}, expected 100")
    lines = loot.get("charm_lines") or []
    if lines:
        sum_ok("loot.json charm_lines", [e.get("w", 0) for e in lines if isinstance(e, dict)])

print(f"data-validate: {len(data_files)} data files, {len(schemas)} schemas, {errors} errors")
sys.exit(1 if errors else 0)
