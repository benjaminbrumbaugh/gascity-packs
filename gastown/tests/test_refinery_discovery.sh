#!/usr/bin/env bash
# Source-backed behavioral test for refinery merge discovery.
#
# This observes the authored formula and prompt blocks, then executes each
# against controlled Beads JSON and remote-ref responses. It proves candidate
# visibility/classification at the shell boundary; it does not prove a live
# refinery session, Dolt durability, or a successful merge.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"
PROMPT="$ROOT/gastown/agents/refinery/prompt.template.md"

fail() {
    printf 'refinery discovery test failed: %s\n' "$*" >&2
    exit 1
}

extract_block() {
    local marker="$1" source="$2" stop="${3:-}"
    python3 - "$marker" "$source" "$stop" <<'PY'
import sys
from pathlib import Path

marker, source, stop = sys.argv[1:]
text = Path(source).read_text(encoding="utf-8")
position = text.index(marker)
start = text.rfind("```bash", 0, position)
end = text.index(stop, position) if stop else text.find("```", position)
if start < 0 or end < 0:
    raise SystemExit(1)
print(text[start + len("```bash"):end], end="")
PY
}

[[ -f "$FORMULA" ]] || fail "missing formula: $FORMULA"
[[ -f "$PROMPT" ]] || fail "missing prompt: $PROMPT"
python3 - "$FORMULA" <<'PY' || fail "refinery formula is not valid TOML"
import sys
import tomllib
with open(sys.argv[1], "rb") as handle:
    tomllib.load(handle)
PY

FORMULA_BLOCK="$(extract_block 'WORK_JSON=$(gc bd list' "$FORMULA")"
PROMPT_BLOCK="$(extract_block 'ORPHAN_JSON=$(gc bd list' "$PROMPT" '# Step 1: Check for an in-progress patrol wisp')"
[[ -n "$FORMULA_BLOCK" ]] || fail "could not extract formula find-work block"
[[ -n "$PROMPT_BLOCK" ]] || fail "could not extract prompt orphan-scan block"

# Contract checks are deliberately scoped to the executable blocks. Other
# status filters in the formula handle rejection/search bookkeeping and are not
# discovery filters.
for block_name in formula prompt; do
    if [[ "$block_name" == formula ]]; then
        block="$FORMULA_BLOCK"
    else
        block="$PROMPT_BLOCK"
    fi
    case "$block" in
        *'--assignee="$GC_AGENT"'*) ;;
        *) fail "$block_name discovery does not key on the current refinery assignee" ;;
    esac
    case "$block" in
        *'--has-metadata-key=branch'*) ;;
        *) fail "$block_name discovery does not require branch metadata" ;;
    esac
    case "$block" in
        *'git ls-remote --exit-code origin "refs/heads/'*) ;;
        *) fail "$block_name discovery does not verify branch reachability on origin" ;;
    esac
    case "$block" in
        *'--status=open'*) fail "$block_name discovery reintroduced a server-side open-only filter" ;;
    esac
    case "$block" in
        *'status == "open" or .status == "in_progress"'*) ;;
        *) fail "$block_name discovery does not accept open and in_progress locally" ;;
    esac
done
case "$PROMPT_BLOCK" in
    *'--metadata-field gc.routed_to='*) fail "orphan scan still trusts stale gc.routed_to metadata" ;;
esac

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/refinery-discovery.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
BIN="$WORKDIR/bin"
mkdir -p "$BIN"

cat >"$BIN/gc" <<'GC_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'gc' >>"$CALL_LOG"
for arg in "$@"; do printf ' <%s>' "$arg" >>"$CALL_LOG"; done
printf '\n' >>"$CALL_LOG"
if [[ "${1:-}" == "bd" && "${2:-}" == "list" ]]; then
    cat "$FIXTURE"
    exit 0
fi
printf 'unexpected gc call: %s\n' "$*" >&2
exit 2
GC_STUB
chmod +x "$BIN/gc"

cat >"$BIN/git" <<'GIT_STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "ls-remote" ]]; then
    case "$*" in
        *'refs/heads/polecat/ready'*) exit 0 ;;
        *) exit 2 ;;
    esac
fi
printf 'unexpected git call: %s\n' "$*" >&2
exit 2
GIT_STUB
chmod +x "$BIN/git"

cat >"$WORKDIR/fixture.json" <<'JSON'
[
  {
    "id": "wf-unpushed",
    "status": "in_progress",
    "assignee": "Wayfinder/gastown.refinery",
    "metadata": {
      "branch": "polecat/not-pushed",
      "gc.routed_to": "Wayfinder/gastown.polecat"
    }
  },
  {
    "id": "wf-pmb",
    "status": "in_progress",
    "assignee": "Wayfinder/gastown.refinery",
    "metadata": {
      "branch": "polecat/ready",
      "gc.routed_to": "Wayfinder/gastown.polecat"
    }
  },
  {
    "id": "wf-closed",
    "status": "closed",
    "assignee": "Wayfinder/gastown.refinery",
    "metadata": {"branch": "polecat/ready"}
  }
]
JSON

run_formula() {
    local output
    output="$(
        export PATH="$BIN:$PATH" CALL_LOG="$WORKDIR/formula.calls" FIXTURE="$WORKDIR/fixture.json"
        export GC_RIG=Wayfinder GC_AGENT=Wayfinder/gastown.refinery
        bash -c "$FORMULA_BLOCK; printf 'SELECTED=%s\\n' \"\$WORK\""
    )"
    [[ "$output" == *'SKIP: wf-unpushed metadata.branch=polecat/not-pushed is not reachable on origin'* ]] ||
        fail "formula did not skip an unpushed branch: $output"
    [[ "$output" == *'SELECTED=wf-pmb'* ]] ||
        fail "formula did not select the in_progress assigned bead: $output"
    ! grep -F -- '<--status=open>' "$WORKDIR/formula.calls" ||
        fail "formula used a server-side open-only filter: $(cat "$WORKDIR/formula.calls")"
    grep -F -- '<--assignee=Wayfinder/gastown.refinery>' "$WORKDIR/formula.calls" >/dev/null ||
        fail "formula did not query the current refinery assignee"
}

run_prompt() {
    local output
    output="$(
        export PATH="$BIN:$PATH" CALL_LOG="$WORKDIR/prompt.calls" FIXTURE="$WORKDIR/fixture.json"
        export GC_RIG=Wayfinder GC_AGENT=Wayfinder/gastown.refinery
        bash -c "$PROMPT_BLOCK"
    )"
    [[ "$output" == *'orphan-merge skip: wf-unpushed metadata.branch=polecat/not-pushed is not reachable on origin'* ]] ||
        fail "prompt did not skip an unpushed branch: $output"
    [[ "$output" == *'orphan-merge candidate: wf-pmb'* ]] ||
        fail "prompt did not surface the in_progress assigned bead with stale routed_to: $output"
    [[ "$output" != *'orphan-merge candidate: wf-closed'* ]] ||
        fail "prompt surfaced a closed bead: $output"
    ! grep -F -- '<--status=open>' "$WORKDIR/prompt.calls" ||
        fail "prompt used a server-side open-only filter: $(cat "$WORKDIR/prompt.calls")"
    grep -F -- '<--assignee=Wayfinder/gastown.refinery>' "$WORKDIR/prompt.calls" >/dev/null ||
        fail "prompt did not query the current refinery assignee"
}

run_formula
run_prompt
printf 'refinery discovery tests passed\n'
