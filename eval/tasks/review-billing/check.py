"""REVIEW.md finds the four planted bugs: a line number within ±4 of the bug, or a description matching it."""
import re

BUGS = {
    "coupon expiry reversed": (160, r"expir"),
    "4th payment retry": (216, r"(> ?3|>= ?3|max(imum)? (of )?3|three|fourth|4th|off.by.one)"),
    "reverse charge `or`": (185, r"(\bor\b.{0,40}(reverse|is_reverse)|reverse.charge.{0,80}(consumer|without|b2c|every|all customers))"),
    "old status not removed": (263, r"(discard|old.status|previous status|stale|two statuses|both status|remov\w+ from the old)"),
}


def check(workdir):
    try:
        review = (workdir / "REVIEW.md").read_text()
    except FileNotFoundError:
        return {"score": 0.0, "notes": "REVIEW.md missing"}
    lines = {int(n) for n in re.findall(r"(?i)(?:line[s]?\s*|L|:)(\d{2,3})\b", review)}
    lower = review.lower()
    found = [name for name, (line, pattern) in BUGS.items()
             if any(abs(n - line) <= 4 for n in lines) or re.search(pattern, lower)]
    return {"score": len(found) / len(BUGS), "notes": f"found {len(found)}/4: {', '.join(found) or 'none'}"}
