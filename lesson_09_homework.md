## Homework — Lesson 9: Catching Prompt Regressions When You Change a Prompt

### The task

1. **Measure the noise floor.** Evaluate `prompts/v1.txt` twice with `--no-cache`, saving to `results/v1a.json` and `results/v1b.json`, then run `compare.py results/v1a.json results/v1b.json --out reports/noise`. Deliverable: `reports/noise/diff.md`.
2. **Isolate concurrency.** Repeat step 1 with `-j 1` added to both eval commands, writing to `reports/noise-serial/`. Deliverable: a "Noise floor" section in `README.md` recording the DRIFT count from both runs.
3. **Fix the regression without losing the punch.** Add a `length_hint` variable to every case in `tests/cases.yaml` and write `prompts/v3.txt` that uses it. Evaluate v3 into `results/v3.json`. Deliverable: `reports/v3/diff.md` comparing v1 to v3.
4. **Gate on drift, not only regressions.** Add a `--max-drift N` flag to `compare.py` that returns exit code 1 when the DRIFT count exceeds N, plus one test in `tests/test_compare.py` proving it.

### You've done it when

- `python3 scripts/compare.py results/v1.json results/v3.json --out reports/v3` prints `✅ 0 regressions introduced` and `echo $?` prints `0`.
- `reports/noise/diff.json` exists and `counts.REGRESSION` is `0`.
- `make test` prints `10 passed`.

### Solution path

Steps 1 and 2 are the same eval command run twice with a different output path — the flags you need are already in `run_regression.sh`: `npx --yes promptfoo@latest eval -c promptfooconfig.yaml --prompts prompts/v1.txt --output results/v1a.json --no-cache`. For the serial run, append `-j 1`. If the noise run shows REGRESSION rows, the model itself is flipping cases near a threshold; look at the word counts for those rows before blaming anything.

Step 3 hinges on the observation that broke v2: one length rule cannot serve two product tiers. Give each case a `length_hint` — `"under 30 words"` for standard, `"50 to 80 words"` for premium — and replace v2's length line with `- Length: {{length_hint}}.` Keep the `min_words` assertion untouched; the test data owns the contract, the prompt just reads it.

Step 4 is the hardest because the flag must interact correctly with `--no-fail`:

```python
parser.add_argument("--max-drift", type=int, default=None, help="fail when DRIFT count exceeds this")
...
if args.max_drift is not None and counts["DRIFT"] > args.max_drift:
    return 1
return 1 if counts["REGRESSION"] and not args.no_fail else 0
```

Decide whether `--no-fail` should also silence the drift gate, and write your test to pin that decision. The fixtures contain exactly one DRIFT case, so `--max-drift 0` should exit 1 and `--max-drift 1` should exit 0.

### What the homework reveals

With `temperature: 0` and a fixed seed, you expect v1-versus-v1 to be identical. On many machines it isn't — not under promptfoo's default concurrency. Ollama batches concurrent requests, and batched matrix maths accumulates floating-point rounding in a different order, nudging a token here and there and cascading through the rest of the output. Run with `-j 1` and the drift usually disappears. The practical consequence: a drift threshold is meaningless until you measure the noise floor at the same concurrency your CI uses. A 0.55 cutoff that is silent locally on a serial run can fire false DRIFT alarms on a parallel CI runner.
