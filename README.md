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
