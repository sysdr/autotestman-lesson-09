#!/usr/bin/env python3
"""Diff two promptfoo result files and report regressions, fixes, and output drift."""
from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

DRIFT_THRESHOLD = 0.55  # word-sequence similarity below this counts as a significant rewrite
ORDER = ["REGRESSION", "FIX", "DRIFT", "STILL_FAILING", "ADDED", "REMOVED", "STABLE"]
TOKEN = re.compile(r"[a-z0-9][a-z0-9'-]*")


@dataclass(frozen=True)
class CaseResult:
    """One test case's outcome under one prompt version."""

    name: str
    passed: bool
    output: str
    reason: str


@dataclass(frozen=True)
class CaseDiff:
    """How one test case changed between the baseline and candidate runs."""

    name: str
    status: str
    old_words: int
    new_words: int
    similarity: float
    reason: str


def extract_rows(data: Any) -> list[dict[str, Any]]:
    """Return per-test result rows from either promptfoo output layout."""
    rows: Any = data.get("results", data) if isinstance(data, dict) else data
    if isinstance(rows, dict):
        rows = rows.get("results", [])
    if not isinstance(rows, list):
        raise ValueError("no results list found in promptfoo output")
    return [row for row in rows if isinstance(row, dict)]


def case_name(row: dict[str, Any]) -> str:
    """Return the test description, falling back to the serialised vars."""
    test_case = row.get("testCase") or {}
    name = test_case.get("description") or row.get("description")
    if name:
        return str(name)
    return json.dumps(row.get("vars") or test_case.get("vars") or {}, sort_keys=True)


def output_text(row: dict[str, Any]) -> str:
    """Return the model output of a row as plain text."""
    output = (row.get("response") or {}).get("output", "")
    return output if isinstance(output, str) else json.dumps(output)


def row_passed(row: dict[str, Any]) -> bool:
    """Return whether every assertion on the row passed."""
    grading = row.get("gradingResult") or {}
    return bool(row.get("success", grading.get("pass", False)))


def failure_reason(row: dict[str, Any]) -> str:
    """Return the first failing assertion's reason, or an empty string when the row passed."""
    if row_passed(row):
        return ""
    grading = row.get("gradingResult") or {}
    for component in grading.get("componentResults") or []:
        if not component.get("pass", True):
            return str(component.get("reason") or "assertion failed")
    return str(grading.get("reason") or row.get("error") or "failed")


def load_results(path: Path) -> dict[str, CaseResult]:
    """Load a promptfoo result file into a map of case name to outcome."""
    data = json.loads(path.read_text(encoding="utf-8"))
    cases: dict[str, CaseResult] = {}
    for row in extract_rows(data):
        name = case_name(row)
        if name in cases:
            print(f"warning: duplicate case '{name}' in {path}; give every test a unique description", file=sys.stderr)
        cases[name] = CaseResult(name, row_passed(row), output_text(row), failure_reason(row))
    return cases


def word_count(text: str) -> int:
    """Count whitespace-separated words the same way the promptfoo assertion does."""
    return len(text.split())


def similarity(old: str, new: str) -> float:
    """Return a 0-1 word-sequence similarity between two outputs."""
    matcher = difflib.SequenceMatcher(None, TOKEN.findall(old.lower()), TOKEN.findall(new.lower()), autojunk=False)
    return round(matcher.ratio(), 2)


def classify(name: str, old: CaseResult | None, new: CaseResult | None, threshold: float) -> CaseDiff:
    """Place one case into exactly one status bucket."""
    if old is None or new is None:
        if new is not None:
            return CaseDiff(name, "ADDED", 0, word_count(new.output), 0.0, "only in the new run")
        if old is not None:
            return CaseDiff(name, "REMOVED", word_count(old.output), 0, 0.0, "only in the old run")
        raise ValueError(f"case '{name}' is missing from both runs")
    score = similarity(old.output, new.output)
    if old.passed and not new.passed:
        status, reason = "REGRESSION", new.reason
    elif new.passed and not old.passed:
        status, reason = "FIX", f"was: {old.reason}"
    elif not new.passed:
        status, reason = "STILL_FAILING", new.reason
    elif score < threshold:
        status, reason = "DRIFT", f"both pass, similarity {score:.2f} < {threshold:.2f}"
    else:
        status, reason = "STABLE", ""
    return CaseDiff(name, status, word_count(old.output), word_count(new.output), score, reason)


def compare(old: dict[str, CaseResult], new: dict[str, CaseResult], threshold: float) -> list[CaseDiff]:
    """Pair cases by name across both runs and classify every pair."""
    diffs = [classify(name, old.get(name), new.get(name), threshold) for name in set(old) | set(new)]
    return sorted(diffs, key=lambda diff: (ORDER.index(diff.status), diff.name))


def count_statuses(diffs: list[CaseDiff]) -> dict[str, int]:
    """Count how many cases landed in each status bucket."""
    counts = {status: 0 for status in ORDER}
    for diff in diffs:
        counts[diff.status] += 1
    return counts


def render_table(diffs: list[CaseDiff]) -> str:
    """Render the diffs as a fixed-width terminal table."""
    width = max([len(diff.name) for diff in diffs] + [len("TEST CASE")]) + 2
    header = f"{'STATUS':<15}{'TEST CASE':<{width}}{'WORDS':>9}{'SIM':>7}  DETAIL"
    lines = [header, "-" * (len(header) + 30)]
    for diff in diffs:
        words = f"{diff.old_words}->{diff.new_words}"
        lines.append(f"{diff.status:<15}{diff.name:<{width}}{words:>9}{diff.similarity:>7.2f}  {diff.reason[:70]}")
    return "\n".join(lines)


def summary_line(diffs: list[CaseDiff], counts: dict[str, int]) -> str:
    """Build the headline verdict naming every regressed case."""
    regressions = [diff.name for diff in diffs if diff.status == "REGRESSION"]
    tail = (
        f"fixes: {counts['FIX']} · drifted: {counts['DRIFT']} · "
        f"still failing: {counts['STILL_FAILING']} · stable: {counts['STABLE']}"
    )
    if not regressions:
        return f"✅ 0 regressions introduced\n   {tail}"
    noun = "regression" if len(regressions) == 1 else "regressions"
    return f"❌ {len(regressions)} {noun} introduced: {', '.join(regressions)}\n   {tail}"


def write_reports(diffs: list[CaseDiff], counts: dict[str, int], old_path: Path, new_path: Path, out_dir: Path, threshold: float) -> tuple[Path, Path]:
    """Write diff.json and diff.md into the output directory and return their paths."""
    out_dir.mkdir(parents=True, exist_ok=True)
    json_path = out_dir / "diff.json"
    md_path = out_dir / "diff.md"
    payload = {
        "old": str(old_path),
        "new": str(new_path),
        "threshold": threshold,
        "counts": counts,
        "cases": [asdict(diff) for diff in diffs],
    }
    json_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    rows = [
        f"| {d.status} | {d.name} | {d.old_words} → {d.new_words} | {d.similarity:.2f} | {d.reason.replace('|', '/')} |"
        for d in diffs
    ]
    markdown = [
        f"# Prompt diff: {old_path.name} → {new_path.name}",
        "",
        "| Status | Test case | Words | Similarity | Detail |",
        "|---|---|---|---|---|",
        *rows,
        "",
    ]
    md_path.write_text("\n".join(markdown), encoding="utf-8")
    return json_path, md_path


def main(argv: list[str] | None = None) -> int:
    """Parse arguments, run the comparison, write reports, and return an exit code."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("old", type=Path, help="baseline result file, e.g. results/v1.json")
    parser.add_argument("new", type=Path, help="candidate result file, e.g. results/v2.json")
    parser.add_argument("--out", type=Path, default=Path("reports"), help="directory for diff.json and diff.md")
    parser.add_argument("--threshold", type=float, default=DRIFT_THRESHOLD, help="similarity below this counts as drift")
    parser.add_argument("--no-fail", action="store_true", help="exit 0 even when regressions exist")
    args = parser.parse_args(argv)

    diffs = compare(load_results(args.old), load_results(args.new), args.threshold)
    counts = count_statuses(diffs)
    print(f"Comparing {args.old} -> {args.new}  (drift threshold {args.threshold:.2f})\n")
    print(render_table(diffs))
    print()
    print(summary_line(diffs, counts))
    json_path, md_path = write_reports(diffs, counts, args.old, args.new, args.out, args.threshold)
    print(f"   reports: {json_path}, {md_path}")
    return 1 if counts["REGRESSION"] and not args.no_fail else 0


if __name__ == "__main__":
    sys.exit(main())
