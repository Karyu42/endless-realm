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

# --- loot / class id cross-references ---
classes_path = root / "classes.json"
loot_path = root / "loot.json"
if loot_path.exists():
    loot = json.loads(loot_path.read_text(encoding="utf-8"))
    tables = loot.get("tables") or {}
    tier_rows = loot.get("tier_rows") or {}
    for rank, tid in (loot.get("rank_tables") or {}).items():
        if tid not in tables:
            err(f"loot.json rank_tables.{rank}: unknown id {tid!r} (not in tables)")
    for tid, tab in tables.items():
        if isinstance(tab, dict):
            row = tab.get("row")
            if row not in tier_rows:
                err(f"loot.json tables.{tid}.row: unknown id {row!r} (not in tier_rows)")
    class_ids = set()
    if classes_path.exists():
        classes_doc = json.loads(classes_path.read_text(encoding="utf-8"))
        for c in classes_doc.get("classes") or []:
            if isinstance(c, dict) and c.get("id"):
                class_ids.add(str(c["id"]))
    weapons = loot.get("weapons") or {}
    weapon_ids = set()
    for cid, w in weapons.items():
        if class_ids and cid not in class_ids:
            err(f"loot.json weapons.{cid}: unknown id {cid!r} (not in classes.json)")
        if isinstance(w, dict) and w.get("id"):
            weapon_ids.add(str(w["id"]))
    for cid in loot.get("class_order") or []:
        if class_ids and cid not in class_ids:
            err(f"loot.json class_order: unknown id {cid!r} (not in classes.json)")
    if classes_path.exists():
        for c in classes_doc.get("classes") or []:
            if not isinstance(c, dict):
                continue
            wid = c.get("weapon_id")
            if wid and wid not in weapon_ids:
                err(
                    f"classes.json {c.get('id')}.weapon_id: unknown id {wid!r} "
                    f"(not in loot.json weapons.*.id)"
                )

# Timer patterns: interval_ticks must match the enemy's fire_interval_ticks.
if enemies_path.exists() and patterns_path.exists():
    for i, enemy in enumerate(enemies_doc.get("enemies") or []):
        if not isinstance(enemy, dict):
            continue
        ai = enemy.get("ai") or {}
        pid = ai.get("pattern")
        if not pid or pid not in patterns_by_id:
            continue
        pat = patterns_by_id[pid]
        if pat.get("trigger") != "timer":
            continue
        if "interval_ticks" in pat and "fire_interval_ticks" in ai:
            if int(pat["interval_ticks"]) != int(ai["fire_interval_ticks"]):
                err(
                    f"enemies.json {enemy.get('id', i)}: fire_interval_ticks "
                    f"{ai['fire_interval_ticks']} != {pid}.interval_ticks {pat['interval_ticks']}"
                )

# Negative checks: packed Driftcap / spore_ring effect fields are required.
_DRIFTCAP_REQUIRED = {
    "spore_ring": ("count", "aim", "angle_offset_cycle_deg", "interval_ticks"),
    "driftcap_spore.ai": ("type", "pattern", "fire_interval_ticks"),
}


def _schema_rejects_missing(schema_path, pack_path, kind, key, field, drop):
    import tempfile

    doc = json.loads(pack_path.read_text(encoding="utf-8"))
    found = False
    for item in doc.get(kind) or []:
        if not isinstance(item, dict) or item.get("id") != key:
            continue
        found = True
        drop(item)
        break
    if not found:
        err(f"{pack_path.name}: missing packed {key!r}")
        return
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / pack_path.name
        path.write_text(json.dumps(doc), encoding="utf-8")
        r = subprocess.run(
            ["check-jsonschema", "--schemafile", str(schema_path), str(path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if r.returncode == 0:
            err(f"{schema_path.name}: missing {key}.{field} should fail validation")


if (schema_dir / "patterns.schema.json").exists() and patterns_path.exists():
    for field in _DRIFTCAP_REQUIRED["spore_ring"]:
        _schema_rejects_missing(
            schema_dir / "patterns.schema.json",
            patterns_path,
            "patterns",
            "spore_ring",
            field,
            lambda item, f=field: item.pop(f, None),
        )

if (schema_dir / "enemies.schema.json").exists() and enemies_path.exists():
    for field in _DRIFTCAP_REQUIRED["driftcap_spore.ai"]:
        def _drop(item, f=field):
            if isinstance(item.get("ai"), dict):
                item["ai"].pop(f, None)
        _schema_rejects_missing(
            schema_dir / "enemies.schema.json",
            enemies_path,
            "enemies",
            "driftcap_spore",
            f"ai.{field}",
            _drop,
        )
if "class_ids" not in globals():
    class_ids = set()
    classes_doc = {"classes": []}

abilities_path = root / "abilities.json"
ability_ids = set()
if abilities_path.exists():
    abilities_doc = json.loads(abilities_path.read_text(encoding="utf-8"))
    for a in abilities_doc.get("abilities") or []:
        if not isinstance(a, dict):
            continue
        aid = a.get("id")
        if aid:
            if aid in ability_ids:
                err(f"abilities.json: duplicate id {aid!r}")
            ability_ids.add(str(aid))
        cid = a.get("class_id")
        if cid and class_ids and cid not in class_ids:
            err(f"abilities.json {aid}: unknown class_id {cid!r} (not in classes.json)")
if class_ids:
    # classes_doc is set when classes.json exists in the loot block above.
    for c in classes_doc.get("classes") or []:
        if not isinstance(c, dict):
            continue
        aid = c.get("ability_id")
        if aid and aid not in ability_ids:
            err(
                f"classes.json {c.get('id')}.ability_id: unknown id {aid!r} "
                f"(not in abilities.json)"
            )

# Negative checks: each v0.1 ability must fail validation if an effect field is missing.
_ABILITY_REQUIRED = {
    "thorn_ward": ("duration_ticks", "damage_taken_mult"),
    "kindle_pulse": ("cast_lock_ticks", "heal_radius_tiles", "heal_max_hp_frac"),
    "slipstep": ("blink_tiles", "invuln_ticks"),
}


def _ability_schema_rejects_missing_fields():
    schema = schema_dir / "abilities.schema.json"
    pack = root / "abilities.json"
    if not schema.exists() or not pack.exists():
        return
    import copy
    import tempfile

    doc = json.loads(pack.read_text(encoding="utf-8"))
    found = {a.get("id") for a in doc.get("abilities") or [] if isinstance(a, dict)}
    for aid, fields in _ABILITY_REQUIRED.items():
        if aid not in found:
            err(f"abilities.json: missing packed ability {aid!r}")
            continue
        for field in fields:
            trial = copy.deepcopy(doc)
            for a in trial.get("abilities") or []:
                if isinstance(a, dict) and a.get("id") == aid:
                    a.pop(field, None)
                    break
            with tempfile.TemporaryDirectory() as tmp:
                path = pathlib.Path(tmp) / "abilities.json"
                path.write_text(json.dumps(trial), encoding="utf-8")
                r = subprocess.run(
                    ["check-jsonschema", "--schemafile", str(schema), str(path)],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                if r.returncode == 0:
                    err(
                        f"abilities.schema.json: missing {aid}.{field} should fail validation"
                    )


_ability_schema_rejects_missing_fields()

# Dungeon spawn enemy ids must exist in enemies.json.
enemy_ids = set()
if enemies_path.exists():
    if "enemies_doc" not in globals():
        enemies_doc = json.loads(enemies_path.read_text(encoding="utf-8"))
    enemy_ids = {
        str(e.get("id"))
        for e in enemies_doc.get("enemies") or []
        if isinstance(e, dict) and e.get("id")
    }
dungeons_dir = root / "dungeons"
if dungeons_dir.exists() and enemy_ids:
    for path in sorted(dungeons_dir.glob("*.json")):
        doc = json.loads(path.read_text(encoding="utf-8"))
        for room in doc.get("rooms") or []:
            if not isinstance(room, dict):
                continue
            for spawn in room.get("spawns") or []:
                if not isinstance(spawn, dict):
                    continue
                eid = spawn.get("enemy_id")
                if eid and eid not in enemy_ids:
                    err(
                        f"{path}: spawn enemy_id {eid!r} is not in enemies.json"
                    )

# Negative checks: packed dungeon and practice portal fields are required.
_DUNGEON_REQUIRED = ("id", "name", "base_level", "rooms", "corridors")
_PRACTICE_PORTAL_REQUIRED = ("x", "y", "radius", "m100", "practice_base_level", "placeholder")


def _dungeon_schema_rejects_missing():
    schema = schema_dir / "dungeons.schema.json"
    pack = root / "dungeons" / "hollowmere_vault.json"
    if not schema.exists() or not pack.exists():
        err("dungeons.schema.json or hollowmere_vault.json is missing")
        return
    import copy
    import tempfile

    doc = json.loads(pack.read_text(encoding="utf-8"))
    for field in _DUNGEON_REQUIRED:
        trial = copy.deepcopy(doc)
        trial.pop(field, None)
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "hollowmere_vault.json"
            path.write_text(json.dumps(trial), encoding="utf-8")
            r = subprocess.run(
                ["check-jsonschema", "--schemafile", str(schema), str(path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            if r.returncode == 0:
                err(f"dungeons.schema.json: missing {field} should fail validation")
    for field in _PRACTICE_PORTAL_REQUIRED:
        trial = copy.deepcopy(doc)
        portal = trial.get("practice_yard_portal")
        if isinstance(portal, dict):
            portal.pop(field, None)
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "hollowmere_vault.json"
            path.write_text(json.dumps(trial), encoding="utf-8")
            r = subprocess.run(
                ["check-jsonschema", "--schemafile", str(schema), str(path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            if r.returncode == 0:
                err(
                    f"dungeons.schema.json: missing practice_yard_portal.{field} should fail validation"
                )


_dungeon_schema_rejects_missing()

print(f"data-validate: {len(data_files)} data files, {len(schemas)} schemas, {errors} errors")
sys.exit(1 if errors else 0)
