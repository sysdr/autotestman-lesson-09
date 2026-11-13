#!/usr/bin/env bash
set -euo pipefail

GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

LESSON_DIR="lesson-09"

echo "${BOLD}${CYAN}════════════════════════════════════════════════════════════${RESET}"
echo "${BOLD}  Testing What AI Builds · Module 1 — Testing LLM Output${RESET}"
echo "${BOLD}  Lesson 9 — Catching Prompt Regressions When You Change a Prompt${RESET}"
echo "${BOLD}  Day 9${RESET}"
echo "${BOLD}${CYAN}════════════════════════════════════════════════════════════${RESET}"

if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
  echo "${YELLOW}Python 3.11+ is required. Found: $(python3 --version 2>&1)${RESET}"
  exit 1
fi
command -v npx >/dev/null 2>&1 || echo "${YELLOW}⚠ npx not found — install Node 20+ before running promptfoo.${RESET}"
command -v ollama >/dev/null 2>&1 || echo "${YELLOW}⚠ ollama CLI not found — the QATP-App container or a local install must serve llama3.2:3b on :11434.${RESET}"

mkdir -p "${LESSON_DIR}/prompts" \
         "${LESSON_DIR}/scripts" \
         "${LESSON_DIR}/tests/fixtures" \
         "${LESSON_DIR}/results" \
         "${LESSON_DIR}/reports"
touch "${LESSON_DIR}/results/.gitkeep" "${LESSON_DIR}/reports/.gitkeep"

echo "${CYAN}▶ writing prompts${RESET}"
cat > "${LESSON_DIR}/prompts/v1.txt" << 'EOF'
You are a copywriter for an online store.
Write a product description for "{{product_name}}" aimed at {{audience}}.
Key features: {{features}}.
Requirements:
- Mention the exact product name "{{product_name}}" at least once.
- Cover at least two of the key features.
- Write between 50 and 80 words in a single paragraph.
- Return only the description text, with no title, quotes, or preamble.
EOF

cat > "${LESSON_DIR}/prompts/v2.txt" << 'EOF'
You are a copywriter for an online store. Readers skim, so be punchy.
Write a product description for "{{product_name}}" aimed at {{audience}}.
Key features: {{features}}.
Requirements:
- Mention the exact product name "{{product_name}}" at least once.
- Cover at least two of the key features.
- Keep it under 30 words. Cut every word that does not sell.
- Return only the description text, with no title, quotes, or preamble.
EOF

echo "${CYAN}▶ writing promptfoo config and test cases${RESET}"
cat > "${LESSON_DIR}/promptfooconfig.yaml" << 'EOF'
# yaml-language-server: $schema=https://promptfoo.dev/config-schema.json
description: "L9 product-description prompt regression"
prompts:
  - id: file://prompts/v1.txt
    label: v1                     # column header in the web UI
  - id: file://prompts/v2.txt
    label: v2
providers:
  - id: ollama:chat:llama3.2:3b   # local model, no API key
    config:
      temperature: 0              # remove sampling noise so diffs reflect the prompt
      seed: 42                    # pin the sampler for repeatable runs
defaultTest:
  assert:
    - type: icontains
      value: "{{product_name}}"
      metric: names_product
    - type: javascript
      metric: min_words
      value: |
        const n = output.trim().split(/\s+/).length;
        const min = Number(context.vars.min_words);
        return { pass: n >= min, score: n >= min ? 1 : 0, reason: `word count ${n} vs min ${min}` };
    - type: javascript
      metric: max_words
      value: |
        const n = output.trim().split(/\s+/).length;
        return { pass: n <= 120, score: n <= 120 ? 1 : 0, reason: `word count ${n} vs max 120` };
    - type: javascript
      metric: covers_features
      value: |
        const keys = String(context.vars.keywords).split('|');
        const hits = keys.filter((k) => output.toLowerCase().includes(k.trim().toLowerCase()));
        return { pass: hits.length >= 1, score: hits.length / keys.length, reason: `mentions ${hits.length}/${keys.length} feature keywords` };
tests: file://tests/cases.yaml
EOF

cat > "${LESSON_DIR}/tests/cases.yaml" << 'EOF'
# Each description is the join key compare.py uses to pair v1 and v2 rows — keep them unique and stable.
- description: standard-wireless-earbuds
  vars:
    product_name: Echo Buds Air
    audience: daily commuters
    features: active noise cancelling | 30-hour battery | sweat resistant
    keywords: noise|battery|sweat        # substrings the coverage assertion looks for
    min_words: 15
- description: standard-yoga-mat
  vars:
    product_name: Grounded Yoga Mat
    audience: beginner yogis
    features: non-slip surface | 6 mm cushioning | carry strap
    keywords: slip|cushion|strap
    min_words: 15
- description: standard-water-bottle
  vars:
    product_name: Trailhead Bottle
    audience: hikers
    features: double-wall insulation | leakproof lid | cold for 24 hours
    keywords: insulat|leak|cold
    min_words: 15
- description: standard-desk-lamp
  vars:
    product_name: Lumen Arc Lamp
    audience: remote workers
    features: glare-free LEDs | five brightness levels | USB-C charging port
    keywords: glare|bright|usb
    min_words: 15
- description: standard-backpack
  vars:
    product_name: Transit 22L Backpack
    audience: university students
    features: padded laptop sleeve | water-resistant fabric | hidden passport pocket
    keywords: laptop|water|pocket
    min_words: 15
- description: standard-phone-stand
  vars:
    product_name: PivotGrip Stand
    audience: people on video calls
    features: 360-degree rotation | aluminium build | folds flat
    keywords: rotat|alumin|fold
    min_words: 15
- description: premium-espresso-machine
  vars:
    product_name: Barista Pro 900
    audience: home baristas
    features: 15-bar Italian pump | PID temperature control | built-in burr grinder | steam wand
    keywords: pump|temperature|grinder|steam
    min_words: 40                        # premium listings need room to justify the price
- description: premium-standing-desk
  vars:
    product_name: Ascend Standing Desk
    audience: people who work from home
    features: dual motors | four memory presets | anti-collision sensor | bamboo top
    keywords: motor|preset|collision|bamboo
    min_words: 40
EOF

echo "${CYAN}▶ writing scripts/compare.py${RESET}"
cat > "${LESSON_DIR}/scripts/compare.py" << 'EOF'
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
EOF

echo "${CYAN}▶ writing scripts/run_regression.sh${RESET}"
cat > "${LESSON_DIR}/scripts/run_regression.sh" << 'EOF'
#!/usr/bin/env bash
# Evaluate prompts/v1.txt and prompts/v2.txt separately, then diff the two runs.
set -euo pipefail

cd "$(dirname "$0")/.."
PROMPTFOO="${PROMPTFOO:-npx --yes promptfoo@latest}"
OLLAMA_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"
export PROMPTFOO_DISABLE_TELEMETRY=1
mkdir -p results reports

tags="$(curl -sf "${OLLAMA_URL}/api/tags" || true)"
if ! grep -q 'llama3.2:3b' <<<"${tags}"; then
  echo "Ollama at ${OLLAMA_URL} has no llama3.2:3b — run: ollama pull llama3.2:3b" >&2
  exit 2
fi

evaluate() {
  local version="$1"
  local status=0
  echo "▶ promptfoo eval  prompts/${version}.txt  ->  results/${version}.json"
  # --no-cache: the cache key ignores model weights, so a cached baseline can predate your last `ollama pull`.
  ${PROMPTFOO} eval \
    -c promptfooconfig.yaml \
    --prompts "prompts/${version}.txt" \
    --output "results/${version}.json" \
    --description "L9 ${version}" \
    --no-cache || status=$?
  # promptfoo exits 100 when assertions fail; anything else means the run itself broke.
  if [[ ${status} -ne 0 && ${status} -ne 100 ]]; then
    echo "promptfoo crashed on ${version} (exit ${status})" >&2
    exit "${status}"
  fi
  if [[ ! -s "results/${version}.json" ]]; then
    echo "results/${version}.json was not written" >&2
    exit 1
  fi
}

evaluate v1
evaluate v2

echo
python3 scripts/compare.py results/v1.json results/v2.json --out reports
EOF

echo "${CYAN}▶ writing recorded fixtures${RESET}"
cat > "${LESSON_DIR}/tests/fixtures/v1_sample.json" << 'EOF'
{
  "evalId": "eval-fixture-v1",
  "results": {
    "version": 3,
    "timestamp": "2026-10-27T07:30:00.000Z",
    "results": [
      {
        "promptIdx": 0,
        "testIdx": 0,
        "testCase": {"description": "premium-espresso-machine", "vars": {"product_name": "Barista Pro 900", "min_words": 40}},
        "vars": {"product_name": "Barista Pro 900", "min_words": 40},
        "response": {"output": "The Barista Pro 900 brings café-grade shots to your kitchen. Its 15-bar Italian pump and PID temperature control pull consistent espresso every morning, while the steam wand textures milk for silky lattes. A built-in burr grinder delivers fresh grounds in seconds, so home baristas never settle for stale coffee again."},
        "success": true,
        "score": 1,
        "gradingResult": {"pass": true, "score": 1, "reason": "All assertions passed", "componentResults": []}
      },
      {
        "promptIdx": 0,
        "testIdx": 1,
        "testCase": {"description": "premium-standing-desk", "vars": {"product_name": "Ascend Standing Desk", "min_words": 40}},
        "vars": {"product_name": "Ascend Standing Desk", "min_words": 40},
        "response": {"output": "The Ascend Standing Desk moves from sitting to standing height in under ten seconds. Dual motors lift heavy setups without wobble, four memory presets remember your favourite heights, and the anti-collision sensor stops the frame instantly if anything gets in the way. A warm bamboo top finishes a desk built for long workdays at home."},
        "success": true,
        "score": 1,
        "gradingResult": {"pass": true, "score": 1, "reason": "All assertions passed", "componentResults": []}
      },
      {
        "promptIdx": 0,
        "testIdx": 2,
        "testCase": {"description": "standard-yoga-mat", "vars": {"product_name": "Grounded Yoga Mat", "min_words": 15}},
        "vars": {"product_name": "Grounded Yoga Mat", "min_words": 15},
        "response": {"output": "This non-slip mat gives you a stable grip through every flow, with 6 mm cushioning that protects your knees and a strap for easy carrying."},
        "success": false,
        "score": 0.75,
        "gradingResult": {"pass": false, "score": 0.75, "reason": "Expected output to contain \"Grounded Yoga Mat\"", "componentResults": [{"pass": false, "score": 0, "reason": "Expected output to contain \"Grounded Yoga Mat\""}]}
      },
      {
        "promptIdx": 0,
        "testIdx": 3,
        "testCase": {"description": "standard-desk-lamp", "vars": {"product_name": "Lumen Arc Lamp", "min_words": 15}},
        "vars": {"product_name": "Lumen Arc Lamp", "min_words": 15},
        "response": {"output": "The Lumen Arc Lamp gives remote workers warm, adjustable light for late sessions, and its USB-C port charges your phone while you read the last email of the day."},
        "success": true,
        "score": 1,
        "gradingResult": {"pass": true, "score": 1, "reason": "All assertions passed", "componentResults": []}
      },
      {
        "promptIdx": 0,
        "testIdx": 4,
        "testCase": {"description": "standard-water-bottle", "vars": {"product_name": "Trailhead Bottle", "min_words": 15}},
        "vars": {"product_name": "Trailhead Bottle", "min_words": 15},
        "response": {"output": "Stay hydrated on every trail with the Trailhead Bottle. Double-wall insulation keeps drinks cold for 24 hours, and the leakproof lid survives any backpack."},
        "success": true,
        "score": 1,
        "gradingResult": {"pass": true, "score": 1, "reason": "All assertions passed", "componentResults": []}
      }
    ]
  }
}
EOF

cat > "${LESSON_DIR}/tests/fixtures/v2_sample.json" << 'EOF'
{
  "evalId": "eval-fixture-v2",
  "results": {
    "version": 3,
    "timestamp": "2026-10-27T07:35:00.000Z",
    "results": [
      {
        "promptIdx": 0,
        "testIdx": 0,
        "testCase": {"description": "premium-espresso-machine", "vars": {"product_name": "Barista Pro 900", "min_words": 40}},
        "vars": {"product_name": "Barista Pro 900", "min_words": 40},
        "response": {"output": "Barista Pro 900: 15-bar pump, PID temperature control, built-in grinder. Café shots at home, every morning."},
        "success": false,
        "score": 0.75,
        "gradingResult": {"pass": false, "score": 0.75, "reason": "word count 16 vs min 40", "componentResults": [{"pass": true, "score": 1, "reason": "Assertion passed"}, {"pass": false, "score": 0, "reason": "word count 16 vs min 40"}]}
      },
      {
        "promptIdx": 0,
        "testIdx": 1,
        "testCase": {"description": "premium-standing-desk", "vars": {"product_name": "Ascend Standing Desk", "min_words": 40}},
        "vars": {"product_name": "Ascend Standing Desk", "min_words": 40},
        "response": {"output": "Ascend Standing Desk. Dual motors, four memory presets, anti-collision safety. Sit or stand in seconds."},
        "success": false,
        "score": 0.75,
        "gradingResult": {"pass": false, "score": 0.75, "reason": "word count 15 vs min 40", "componentResults": [{"pass": true, "score": 1, "reason": "Assertion passed"}, {"pass": false, "score": 0, "reason": "word count 15 vs min 40"}]}
      },
      {
        "promptIdx": 0,
        "testIdx": 2,
        "testCase": {"description": "standard-yoga-mat", "vars": {"product_name": "Grounded Yoga Mat", "min_words": 15}},
        "vars": {"product_name": "Grounded Yoga Mat", "min_words": 15},
        "response": {"output": "Grounded Yoga Mat: non-slip grip, 6 mm cushioning that saves your knees, and a carry strap. Flow anywhere."},
        "success": true,
        "score": 1,
        "gradingResult": {"pass": true, "score": 1, "reason": "All assertions passed", "componentResults": []}
      },
      {
        "promptIdx": 0,
        "testIdx": 3,
        "testCase": {"description": "standard-desk-lamp", "vars": {"product_name": "Lumen Arc Lamp", "min_words": 15}},
        "vars": {"product_name": "Lumen Arc Lamp", "min_words": 15},
        "response": {"output": "Glare-free LEDs. Five brightness levels. One USB-C port. Meet the Lumen Arc Lamp, built for focus."},
        "success": true,
        "score": 1,
        "gradingResult": {"pass": true, "score": 1, "reason": "All assertions passed", "componentResults": []}
      },
      {
        "promptIdx": 0,
        "testIdx": 4,
        "testCase": {"description": "standard-water-bottle", "vars": {"product_name": "Trailhead Bottle", "min_words": 15}},
        "vars": {"product_name": "Trailhead Bottle", "min_words": 15},
        "response": {"output": "Stay hydrated on every trail with the Trailhead Bottle. Double-wall insulation keeps drinks cold for 24 hours, and the leakproof lid survives every backpack."},
        "success": true,
        "score": 1,
        "gradingResult": {"pass": true, "score": 1, "reason": "All assertions passed", "componentResults": []}
      }
    ]
  }
}
EOF

echo "${CYAN}▶ writing tests/test_compare.py${RESET}"
cat > "${LESSON_DIR}/tests/test_compare.py" << 'EOF'
"""Unit tests for scripts/compare.py using recorded promptfoo fixtures."""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "fixtures"


def load_compare_module() -> ModuleType:
    """Import scripts/compare.py as a module without packaging it."""
    spec = importlib.util.spec_from_file_location("compare", ROOT / "scripts" / "compare.py")
    if spec is None or spec.loader is None:
        raise ImportError("cannot load scripts/compare.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["compare"] = module  # dataclasses resolve annotations through sys.modules
    spec.loader.exec_module(module)
    return module


compare = load_compare_module()


@pytest.fixture(scope="module")
def diffs() -> list[Any]:
    """Return the classified diff between the v1 and v2 fixtures."""
    old = compare.load_results(FIXTURES / "v1_sample.json")
    new = compare.load_results(FIXTURES / "v2_sample.json")
    return compare.compare(old, new, compare.DRIFT_THRESHOLD)


def names_with(diffs: list[Any], status: str) -> list[str]:
    """Return the names of cases with the given status."""
    return [diff.name for diff in diffs if diff.status == status]


def test_two_regressions_named(diffs: list[Any]) -> None:
    """Both premium cases flip from pass to fail."""
    assert names_with(diffs, "REGRESSION") == ["premium-espresso-machine", "premium-standing-desk"]


def test_regression_reason_mentions_word_count(diffs: list[Any]) -> None:
    """The regression reason carries the failing assertion's message."""
    reasons = [diff.reason for diff in diffs if diff.status == "REGRESSION"]
    assert all(reason.startswith("word count") and reason.endswith("vs min 40") for reason in reasons)


def test_fix_detected(diffs: list[Any]) -> None:
    """A case that failed in v1 and passes in v2 counts as a fix."""
    assert names_with(diffs, "FIX") == ["standard-yoga-mat"]


def test_drift_when_both_pass(diffs: list[Any]) -> None:
    """A rewritten output that still passes is flagged as drift."""
    assert names_with(diffs, "DRIFT") == ["standard-desk-lamp"]


def test_stable_case_not_flagged(diffs: list[Any]) -> None:
    """A near-identical output stays stable."""
    assert names_with(diffs, "STABLE") == ["standard-water-bottle"]


def test_exit_code_blocks_regressions(tmp_path: Path) -> None:
    """main() returns 1 when regressions exist and writes both reports."""
    code = compare.main([str(FIXTURES / "v1_sample.json"), str(FIXTURES / "v2_sample.json"), "--out", str(tmp_path)])
    assert code == 1
    assert (tmp_path / "diff.json").is_file() and (tmp_path / "diff.md").is_file()


def test_no_fail_flag_exits_zero(tmp_path: Path) -> None:
    """--no-fail reports regressions without failing the process."""
    code = compare.main([str(FIXTURES / "v1_sample.json"), str(FIXTURES / "v2_sample.json"), "--out", str(tmp_path), "--no-fail"])
    assert code == 0


def test_added_and_removed_cases() -> None:
    """Cases present in only one run are reported instead of silently dropped."""
    old = {"gone": compare.CaseResult("gone", True, "old words here", "")}
    new = {"fresh": compare.CaseResult("fresh", True, "new words", "")}
    statuses = {diff.name: diff.status for diff in compare.compare(old, new, 0.55)}
    assert statuses == {"gone": "REMOVED", "fresh": "ADDED"}


def test_extract_rows_accepts_flat_list() -> None:
    """Older promptfoo exports with a top-level list still parse."""
    assert compare.extract_rows([{"success": True}]) == [{"success": True}]
EOF

cat > "${LESSON_DIR}/requirements.txt" << 'EOF'
pytest>=8.0
EOF

echo "${CYAN}▶ writing Makefile and README${RESET}"
cat > "${LESSON_DIR}/Makefile" << 'EOF'
# Shortcuts for Lesson 9 — prompt regression diffing.
PROMPTFOO ?= npx --yes promptfoo@latest
PYTHON ?= python3
export PROMPTFOO_DISABLE_TELEMETRY := 1

.PHONY: help check regress compare sidebyside view test demo clean

help:
	@echo "make demo        diff the recorded fixtures (no Ollama needed)"
	@echo "make test        run the compare.py unit tests"
	@echo "make check       verify npx and Ollama llama3.2:3b are available"
	@echo "make regress     eval v1 and v2 live, then diff them"
	@echo "make compare     re-diff existing results/v1.json and results/v2.json"
	@echo "make sidebyside  eval both prompts in one run for the web UI"
	@echo "make view        open the promptfoo web UI on :15500"

check:
	@command -v npx >/dev/null || (echo "npx missing: install Node 20+" && exit 1)
	@curl -sf $${OLLAMA_BASE_URL:-http://localhost:11434}/api/tags | grep -q 'llama3.2:3b' || (echo "run: ollama pull llama3.2:3b" && exit 1)
	@echo "✅ toolchain ready"

regress:
	./scripts/run_regression.sh

compare:
	$(PYTHON) scripts/compare.py results/v1.json results/v2.json --out reports

sidebyside:
	-$(PROMPTFOO) eval -c promptfooconfig.yaml --description "L9 v1 vs v2"

view:
	$(PROMPTFOO) view --yes

test:
	$(PYTHON) -m pytest -q tests

demo:
	$(PYTHON) scripts/compare.py tests/fixtures/v1_sample.json tests/fixtures/v2_sample.json --out reports/fixture --no-fail

clean:
	rm -rf results/*.json reports/fixture reports/diff.json reports/diff.md
EOF

cat > "${LESSON_DIR}/README.md" << 'EOF'
# Lesson 9 — Catching Prompt Regressions When You Change a Prompt

Two prompt versions, one test suite, and a diff that names every case that flipped.

## Layout

- `prompts/v1.txt` — baseline prompt (50–80 words)
- `prompts/v2.txt` — "punchier" prompt with a deliberate regression (under 30 words)
- `tests/cases.yaml` — 8 named cases; premium products require 40+ words
- `promptfooconfig.yaml` — Ollama llama3.2:3b provider plus shared assertions
- `scripts/run_regression.sh` — evaluates each prompt into `results/`, then diffs
- `scripts/compare.py` — pairs rows by test description and buckets them as REGRESSION / FIX / DRIFT / STILL_FAILING / STABLE
- `tests/` — pytest suite plus recorded fixtures

## Run

```bash
make demo       # offline: prints "❌ 2 regressions introduced: ..."
make test       # 9 passed
make regress    # live run against Ollama; exits 1 on regressions
make sidebyside && make view   # http://localhost:15500
```

On WSL against Windows Ollama, localhost may not reach the host API. Point the scripts at the Windows host first:

```bash
export OLLAMA_BASE_URL=http://host.docker.internal:11434
make check && make regress
```

## Course materials

- [lesson_09_article.md](lesson_09_article.md) — lesson write-up (implementation guide)
- [lesson_09_homework.md](lesson_09_homework.md) — homework
- [lesson_09_diagram1_data_flow.svg](lesson_09_diagram1_data_flow.svg) / [lesson_09_diagram2_before_after.svg](lesson_09_diagram2_before_after.svg)
- [setup_lesson_09.sh](setup_lesson_09.sh) — regenerates this workspace from a parent folder

## Rules

Test descriptions are join keys. Renaming one shows up as one REMOVED plus one ADDED case, not a regression.
EOF

chmod +x "${LESSON_DIR}/scripts/run_regression.sh" "${LESSON_DIR}/scripts/compare.py"

run_test() {
  echo
  echo "${CYAN}▶ run_test: diffing recorded fixtures (no Ollama needed)${RESET}"
  local output
  output="$(cd "${LESSON_DIR}" && python3 scripts/compare.py tests/fixtures/v1_sample.json tests/fixtures/v2_sample.json --out reports/fixture --no-fail 2>&1)" || true
  echo "${output}"
  if grep -q "2 regressions introduced: premium-espresso-machine, premium-standing-desk" <<<"${output}"; then
    echo "${GREEN}✅ PASSED — compare.py names both premium regressions${RESET}"
    return 0
  fi
  echo "${YELLOW}❌ FAILED — expected '2 regressions introduced' in the output${RESET}"
  return 1
}

verify_result() {
  local report="${LESSON_DIR}/reports/fixture/diff.json"
  if [[ ! -s "${report}" ]]; then
    echo "${YELLOW}❌ VERDICT: ${report} was not written${RESET}"
    return 1
  fi
  if python3 - "${report}" << 'PY'
import json
import sys
from pathlib import Path

counts = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["counts"]
expected = {"REGRESSION": 2, "FIX": 1, "DRIFT": 1, "STABLE": 1}
sys.exit(0 if all(counts[key] == value for key, value in expected.items()) else 1)
PY
  then
    echo "${GREEN}${BOLD}✅ VERDICT: diff.json holds 2 regressions, 1 fix, 1 drift, 1 stable — Lesson 9 is wired correctly.${RESET}"
    return 0
  fi
  echo "${YELLOW}❌ VERDICT: diff.json counts do not match the fixture expectations${RESET}"
  return 1
}

TEST_STATUS=0
run_test || TEST_STATUS=1
verify_result || TEST_STATUS=1

echo
echo "${BOLD}${CYAN}NEXT STEPS${RESET}"
echo "${BOLD}1.${RESET} cd ${LESSON_DIR} && make test"
echo "   expected: ${GREEN}9 passed${RESET}"
echo "${BOLD}2.${RESET} ollama pull llama3.2:3b && make check"
echo "   expected: ${GREEN}✅ toolchain ready${RESET}"
echo "${BOLD}3.${RESET} make regress"
echo "   expected: ${GREEN}❌ 2 regressions introduced: premium-espresso-machine, premium-standing-desk${RESET} then make: *** [regress] Error 1"
echo "${BOLD}4.${RESET} cat reports/diff.md"
echo "   expected: ${GREEN}| REGRESSION | premium-espresso-machine | 5x → 2x | ... | word count 2x vs min 40 |${RESET}"
echo "${BOLD}5.${RESET} make sidebyside && make view"
echo "   expected: ${GREEN}browser opens http://localhost:15500 with v1 and v2 columns; premium rows red under v2${RESET}"

exit "${TEST_STATUS}"
