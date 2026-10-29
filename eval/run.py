#!/usr/bin/python3 -I
"""R1: does delegating save the conductor's usage at the same quality?

Each task runs through `claude -p` twice per round: with the `delegate` MCP server and without any MCP server.
Every run starts from a fresh copy of the task's `input/` (a git repo, so the model can `git diff`). We record the
conductor's cost and tokens from the final `result` event, count tool calls, run the task's automatic check and ask a
judge model to score the result against the task's rubric.

    eval/run.py --tasks translate-locale,write-usage-docs --runs 1 --model sonnet
    eval/run.py --summary eval/results/<dir>      # rebuild summary.md from results.jsonl

Results go to eval/results/<timestamp>/ (git-ignored): results.jsonl, summary.md and `work`, a link to the run
directories with the files and the raw stream of every run. Those live outside this repo ($DELEGATE_EVAL_WORK,
default /tmp/delegate-eval): Claude Code reads every CLAUDE.md up the directory tree, and this repo's would add
~30 KB to every run.

A task is tasks/<id>/ with task.json (prompt, artifacts, rubric, judge_inputs, judge_reference), input/ and
check.py: `check(workdir)` returns {"score": 0..1, "notes": str}; an optional `setup(workdir)` replaces the default
"git init + one commit" (e.g. to build a history or export a repo snapshot).
"""
import argparse
import importlib.util
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

EVAL = Path(__file__).resolve().parent
TASKS = EVAL / "tasks"
DELEGATE = os.environ.get("DELEGATE_MCP", "/Applications/Delegate.app/Contents/Helpers/delegate-mcp")
WORK = Path(os.environ.get("DELEGATE_EVAL_WORK", Path(tempfile.gettempdir()) / "delegate-eval"))

# The same tools for both variants, so the only difference is the delegate server.
ALLOWED = [
    "Read", "Edit", "Write", "Glob", "Grep",
    "Bash(git diff:*)", "Bash(git status:*)", "Bash(ls:*)", "Bash(python3:*)",
    "mcp__delegate__delegate", "mcp__delegate__delegate_result", "mcp__delegate__list_models",
    "mcp__delegate__delegate_agent",
]


def load_task(task_id):
    task = json.loads((TASKS / task_id / "task.json").read_text())
    task["id"] = task_id
    return task


def all_tasks():
    return sorted(p.name for p in TASKS.iterdir() if (p / "task.json").exists())


def load_check(task):
    path = TASKS / task["id"] / "check.py"
    spec = importlib.util.spec_from_file_location(f"check_{task['id'].replace('-', '_')}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prepare(task, workdir):
    shutil.copytree(TASKS / task["id"] / "input", workdir)
    module = load_check(task)
    if hasattr(module, "setup"):
        module.setup(Path(workdir))
        return
    git = lambda *a: subprocess.run(["git", *a], cwd=workdir, check=True, capture_output=True)
    git("init", "-q")
    git("add", "-A")
    git("-c", "user.name=eval", "-c", "user.email=eval@example.com", "commit", "-q", "-m", "input")


def mcp_config(variant, path):
    servers = {"delegate": {"command": DELEGATE}} if variant == "delegate" else {}
    path.write_text(json.dumps({"mcpServers": servers}))


def claude(prompt, cwd, model, mcp, stream_path, timeout, allowed):
    cmd = ["claude", "-p", prompt, "--model", model, "--output-format", "stream-json", "--verbose",
           "--strict-mcp-config", "--mcp-config", str(mcp), "--no-session-persistence",
           "--permission-mode", "acceptEdits", "--allowedTools", ",".join(allowed)]
    started = time.time()
    with open(stream_path, "w") as out:
        try:
            subprocess.run(cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, timeout=timeout)
        except subprocess.TimeoutExpired:
            pass
    return time.time() - started


def parse_stream(path):
    """Final result event plus tool-call counts from the assistant messages."""
    result, tools = None, {}
    for line in Path(path).read_text().splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "result":
            result = event
        if event.get("type") == "assistant":
            for block in event.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    tools[block["name"]] = tools.get(block["name"], 0) + 1
    return result, tools


def conductor_usage(result, model):
    """Cost and tokens of the conductor model only (Claude Code also calls a small model for housekeeping)."""
    usage = (result or {}).get("modelUsage", {})
    picked = {k: v for k, v in usage.items() if model in k} or usage
    total = lambda key: sum(v.get(key, 0) or 0 for v in picked.values())
    return {
        "cost_usd": round(total("costUSD"), 4),
        "input_tokens": total("inputTokens"),
        "output_tokens": total("outputTokens"),
        "cache_read_tokens": total("cacheReadInputTokens"),
        "cache_write_tokens": total("cacheCreationInputTokens"),
        "models": sorted(picked),
    }


def run_check(task, workdir):
    try:
        return load_check(task).check(Path(workdir))
    except Exception as e:  # a broken artifact must not stop the whole run
        return {"score": 0.0, "notes": f"check crashed: {e!r}"}


def judge(task, workdir, model, scratch):
    """Score 1-5 against the task's rubric; the judge sees inputs and artifacts as text, no tools."""
    def read(rel, limit=40000):
        p = Path(workdir) / rel
        if not p.exists():
            return f"(missing: {rel})"
        text = p.read_text(errors="replace")
        return text if len(text) <= limit else text[:limit] + "\n…(truncated)"

    parts = [f"## Task given to the assistant\n{task['prompt']}", f"## Rubric\n{task['rubric']}"]
    parts += [f"## Input file {rel}\n```\n{read(rel)}\n```" for rel in task.get("judge_inputs", [])]
    if task.get("judge_reference"):
        parts.append(f"## Reference (not shown to the assistant)\n```\n{read(TASKS / task['id'] / task['judge_reference'])}\n```")
    parts += [f"## Output file {rel}\n```\n{read(rel)}\n```" for rel in task["artifacts"]]
    parts.append('Score the output from 1 (unusable) to 5 (as good as a careful expert would do). Reply with JSON only: '
                 '{"score": <1-5>, "issues": ["short issue", ...]}')
    scratch.mkdir(parents=True, exist_ok=True)
    empty = scratch / "empty-mcp.json"
    empty.write_text('{"mcpServers": {}}')
    cmd = ["claude", "-p", "--model", model, "--output-format", "json", "--strict-mcp-config", "--mcp-config", str(empty),
           "--no-session-persistence"]
    proc = subprocess.run(cmd, cwd=scratch, input="\n\n".join(parts), capture_output=True, text=True, timeout=600)
    try:
        out = json.loads(proc.stdout)
        text = out.get("result", "")
        verdict = json.loads(text[text.index("{"):text.rindex("}") + 1])
        return {"score": verdict.get("score"), "issues": verdict.get("issues", []),
                "cost_usd": round(out.get("total_cost_usd", 0), 4)}
    except Exception as e:
        return {"score": None, "issues": [f"judge failed: {e!r}: {proc.stdout[-300:]}"], "cost_usd": 0}


def summarize(out_dir):
    rows = [json.loads(l) for l in (out_dir / "results.jsonl").read_text().splitlines() if l.strip()]
    failed = [r for r in rows if r.get("error")]
    rows = [r for r in rows if not r.get("error")]   # np. wyczerpany limit sesji: przebieg bez wyniku
    lines = ["| Task | Variant | Runs | Conductor $ (median) | Cache read (k) | Cache write (k) | Out tokens | Turns | Seconds "
             "| delegate / agent calls | Check | Judge |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    by = {}
    for r in rows:
        by.setdefault((r["task"], r["variant"]), []).append(r)
    med = lambda xs: statistics.median(xs) if xs else None
    savings = []
    for task in sorted({r["task"] for r in rows}):
        costs = {}
        for variant in ("baseline", "delegate"):
            rs = by.get((task, variant), [])
            if not rs:
                continue
            cost = med([r["conductor"]["cost_usd"] for r in rs])
            costs[variant] = cost
            calls = med([r["tools"].get("mcp__delegate__delegate", 0) for r in rs])
            agent = med([r["tools"].get("mcp__delegate__delegate_agent", 0) for r in rs])
            judge_scores = [r["judge"]["score"] for r in rs if r["judge"].get("score") is not None]
            k = lambda key: f"{med([r['conductor'][key] for r in rs]) / 1000:.0f}"
            lines.append(f"| {task} | {variant} | {len(rs)} | {cost:.4f} | {k('cache_read_tokens')} | {k('cache_write_tokens')} "
                         f"| {med([r['conductor']['output_tokens'] for r in rs])} | {med([r['turns'] or 0 for r in rs])} "
                         f"| {med([r['seconds'] for r in rs])} | {calls} / {agent} | {med([r['check']['score'] for r in rs]):.2f} "
                         f"| {med(judge_scores) if judge_scores else '–'} |")
        if costs.get("baseline") and "delegate" in costs:
            savings.append((task, 1 - costs["delegate"] / costs["baseline"]))
    lines.append("")
    if failed:
        lines.append(f"Skipped {len(failed)} failed run(s): " + ", ".join(f"{r['task']}-{r['variant']}-{r['run']}" for r in failed))
    lines += [f"- {task}: delegate saves {s:+.0%} of the conductor's cost" for task, s in savings]
    (out_dir / "summary.md").write_text("\n".join(lines) + "\n")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tasks", help="comma-separated task ids (default: all)")
    ap.add_argument("--variants", default="baseline,delegate")
    ap.add_argument("--runs", type=int, default=2)
    ap.add_argument("--model", default="opus", help="conductor model")
    ap.add_argument("--judge-model", default="sonnet")
    ap.add_argument("--no-judge", action="store_true", help="skip the judge (smoke tests of new tasks)")
    ap.add_argument("--timeout", type=int, default=900, help="seconds per run")
    ap.add_argument("--summary", type=Path, help="only rebuild summary.md of an existing results directory")
    args = ap.parse_args()
    if args.summary:
        print(summarize(args.summary))
        return

    tasks = [load_task(t) for t in (args.tasks.split(",") if args.tasks else all_tasks())]
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = EVAL / "results" / stamp
    out_dir.mkdir(parents=True)
    work = WORK / stamp
    work.mkdir(parents=True)
    (out_dir / "work").symlink_to(work)
    (out_dir / "config.json").write_text(json.dumps(vars(args), default=str, indent=1))
    with open(out_dir / "results.jsonl", "a") as results:
        for n in range(args.runs):
            for task in tasks:
                for variant in args.variants.split(","):
                    name = f"{task['id']}-{variant}-{n + 1}"
                    workdir = work / name
                    prepare(task, workdir)
                    mcp = work / f"{name}.mcp.json"
                    mcp_config(variant, mcp)
                    print(f"→ {name}", flush=True)
                    seconds = claude(task["prompt"], workdir, args.model, mcp, work / f"{name}.jsonl",
                                     args.timeout, ALLOWED)
                    result, tools = parse_stream(work / f"{name}.jsonl")
                    row = {
                        "task": task["id"], "variant": variant, "run": n + 1, "seconds": round(seconds),
                        "error": (result or {}).get("is_error", True) and (result or {}).get("result", "no result event"),
                        "turns": (result or {}).get("num_turns"), "total_cost_usd": (result or {}).get("total_cost_usd"),
                        "conductor": conductor_usage(result, args.model), "tools": tools,
                        "check": run_check(task, workdir),
                        "judge": {"score": None, "issues": [], "cost_usd": 0} if args.no_judge
                                 else judge(task, workdir, args.judge_model, work / "judge"),
                    }
                    results.write(json.dumps(row) + "\n")
                    results.flush()
                    print(f"  ${row['conductor']['cost_usd']} · check {row['check']['score']:.2f} · judge {row['judge']['score']}"
                          f" · tools {tools}" + (f" · ERROR {row['error']}" if row["error"] else ""), flush=True)
    print(summarize(out_dir))
    print(f"\nResults: {out_dir}")


if __name__ == "__main__":
    main()
