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
