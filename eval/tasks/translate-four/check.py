"""Four locale files: each with the same keys as en.json, placeholders kept, nothing left in English."""
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
    en = dict(leaves(json.loads((workdir / "locales/en.json").read_text())))
    scores, notes = [], []
    for lang in ("pl", "de", "fr", "es"):
        try:
            other = dict(leaves(json.loads((workdir / f"locales/{lang}.json").read_text())))
        except Exception as e:
            scores.append(0.0)
            notes.append(f"{lang}: missing or invalid ({type(e).__name__})")
            continue
        missing = [k for k in en if k not in other]
        broken = [k for k in en if k in other and set(PLACEHOLDER.findall(str(en[k]))) - set(PLACEHOLDER.findall(str(other[k])))]
        english = [k for k in en if k in other and str(en[k]) == str(other[k]) and len(str(en[k])) > 12]
        ok = len(en) - len(missing) - len(broken) - len(english)
        scores.append(max(ok, 0) / len(en))
        notes.append(f"{lang}: missing {len(missing)}, placeholders lost {len(broken)}, in English {len(english)}")
    return {"score": round(sum(scores) / 4, 3), "notes": "; ".join(notes)}
