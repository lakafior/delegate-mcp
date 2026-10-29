"""pl.json: valid JSON, the same key paths as en.json, placeholders kept in every string."""
import json
import re

PLACEHOLDER = re.compile(r"\{(\w+)[,}]")


def leaves(obj, prefix=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from leaves(v, f"{prefix}.{k}" if prefix else k)
    else:
        yield prefix, obj


def check(workdir):
    try:
        en = dict(leaves(json.loads((workdir / "locales/en.json").read_text())))
        pl = dict(leaves(json.loads((workdir / "locales/pl.json").read_text())))
    except Exception as e:
        return {"score": 0.0, "notes": f"missing or invalid JSON: {e}"}
    missing = sorted(set(en) - set(pl))
    extra = sorted(set(pl) - set(en))
    broken = [k for k in en if k in pl and set(PLACEHOLDER.findall(str(en[k]))) - set(PLACEHOLDER.findall(str(pl[k])))]
    untranslated = [k for k in en if k in pl and str(en[k]) == str(pl[k]) and len(str(en[k])) > 12]
    ok = len(en) - len(missing) - len(broken) - len(untranslated)
    return {"score": round(max(ok, 0) / max(len(en), 1), 3),
            "notes": f"{len(en)} keys, missing {len(missing)}, extra {len(extra)}, placeholders lost {len(broken)}, "
                     f"left in English {len(untranslated)}"}
