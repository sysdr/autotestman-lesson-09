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
