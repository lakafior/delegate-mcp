"""orders.json: 25 orders valid against the schema subset used by order.schema.json, unique ids, enum coverage."""
import json
import re
from datetime import datetime

TYPES = {"string": str, "integer": int, "number": (int, float), "object": dict, "array": list, "null": type(None),
         "boolean": bool}


def errors(value, schema, path="$"):
    out = []
    types = schema.get("type")
    if types:
        types = types if isinstance(types, list) else [types]
        ok = any(isinstance(value, TYPES[t]) and not (t in ("integer", "number") and isinstance(value, bool)) for t in types)
        if not ok:
            return [f"{path}: expected {types}"]
    if value is None:
        return out
    if "enum" in schema and value not in schema["enum"]:
        out.append(f"{path}: {value!r} not in enum")
    if isinstance(value, str):
        if "pattern" in schema and not re.search(schema["pattern"], value):
            out.append(f"{path}: {value!r} doesn't match pattern")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            out.append(f"{path}: too long")
        if schema.get("format") == "date-time":
            try:
                datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError:
                out.append(f"{path}: bad date-time")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            out.append(f"{path}: below minimum")
        if "maximum" in schema and value > schema["maximum"]:
            out.append(f"{path}: above maximum")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            out.append(f"{path}: not above exclusiveMinimum")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                out.append(f"{path}: missing {key}")
        props = schema.get("properties", {})
        for key, sub in value.items():
            if key in props:
                out += errors(sub, props[key], f"{path}.{key}")
            elif schema.get("additionalProperties") is False:
                out.append(f"{path}: unexpected {key}")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0) or len(value) > schema.get("maxItems", 10**9):
            out.append(f"{path}: {len(value)} items")
        for i, item in enumerate(value):
            out += errors(item, schema.get("items", {}), f"{path}[{i}]")
    return out


def check(workdir, expected=25):
    schema = json.loads((workdir / "schema/order.schema.json").read_text())
    try:
        orders = json.loads((workdir / "fixtures/orders.json").read_text())
    except Exception as e:
        return {"score": 0.0, "notes": f"missing or invalid JSON: {e}"}
    if not isinstance(orders, list):
        return {"score": 0.0, "notes": "not an array"}
    bad = {i: errors(o, schema) for i, o in enumerate(orders)}
    bad = {i: e for i, e in bad.items() if e}
    ids = [o.get("id") for o in orders if isinstance(o, dict)]
    props = schema["properties"]
    dicts = [o for o in orders if isinstance(o, dict)]
    coverage = []
    for values, pick in [(props["status"]["enum"], lambda o: o.get("status")),
                         (props["currency"]["enum"], lambda o: o.get("currency")),
                         (props["shipping"]["properties"]["method"]["enum"], lambda o: (o.get("shipping") or {}).get("method")),
                         (props["customer"]["properties"]["country"]["enum"], lambda o: (o.get("customer") or {}).get("country"))]:
        seen = {pick(o) for o in dicts}
        coverage.append(len(seen & set(values)) / len(values))
    # Ten sam SKU w tej samej walucie powinien mieć jedną cenę (katalog), inaczej dane są nierealistyczne.
    prices = {}
    for o in dicts:
        for item in o.get("items") or []:
            if isinstance(item, dict):
                prices.setdefault((item.get("sku"), o.get("currency")), set()).add(item.get("unitPrice"))
    inconsistent = sum(1 for p in prices.values() if len(p) > 1)
    edges = {"1 item": any(len(o.get("items") or []) == 1 for o in dicts),
             "6 items": any(len(o.get("items") or []) == 6 for o in dicts),
             "vatId set": any((o.get("customer") or {}).get("vatId") for o in dicts),
             "long notes": any(len(o.get("notes") or "") > 100 for o in dicts)}
    valid = (len(orders) - len(bad)) / expected if len(orders) == expected else 0.0
    score = (valid * (1.0 if len(set(ids)) == len(ids) else 0.5) * min(coverage)
             * (sum(edges.values()) / len(edges)) * (1.0 if inconsistent == 0 else 0.8))
    first = next(iter(bad.values()), [])[:2]
    return {"score": round(score, 3),
            "notes": f"{len(orders)} orders, invalid {len(bad)}, unique ids {len(set(ids)) == len(ids)}, "
                     f"coverage {[round(c, 2) for c in coverage]}, missing edge cases {[k for k, v in edges.items() if not v] or 'none'}, SKUs with several prices {inconsistent}, e.g. {first}"}
