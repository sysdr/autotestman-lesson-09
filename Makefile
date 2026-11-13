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
