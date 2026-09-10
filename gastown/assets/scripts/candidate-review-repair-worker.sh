#!/usr/bin/env bash
# candidate-review-repair-worker — deterministic git side of the pack loop.
#
# The model owns interpretation of the persisted exact correction. This worker
# owns only the mechanical boundary after that correction is committed:
# validated explicit paths, current-target rebase, configured gates, leased
# push, and durable review handoff evidence.
set -euo pipefail

BEAD_ID="${1:-}"
if [ -z "$BEAD_ID" ]; then
    echo "candidate-review-repair-worker: bead id is required" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "candidate-review-repair-worker: jq is required" >&2
    exit 1
fi
if [ -z "${GC_AGENT:-}" ]; then
    echo "candidate-review-repair-worker: GC_AGENT is required for single-writer evidence" >&2
    exit 1
fi

fail_state() {
    local reason="$1"
    if ! gc bd update "$BEAD_ID" \
        --set-metadata gc.candidate_review_state=repair_failed \
        --set-metadata gc.candidate_review_last_error="$reason" \
        --append-notes "Candidate repair stopped safely: $reason" >/dev/null; then
        echo "candidate-review-repair-worker: failed to persist repair failure: $reason" >&2
    fi
    echo "candidate-review-repair-worker: $reason" >&2
    return 1
}

BEAD_JSON=""
if ! BEAD_JSON="$(gc bd show "$BEAD_ID" --json)"; then
    echo "candidate-review-repair-worker: unable to read $BEAD_ID" >&2
    exit 1
fi
if ! printf '%s' "$BEAD_JSON" | jq -e 'type == "array" and length == 1' >/dev/null 2>&1; then
    fail_state "bead lookup returned malformed or ambiguous JSON" || exit 1
fi
BEAD="$(printf '%s' "$BEAD_JSON" | jq -c '.[0]')"

# Claim is idempotent for the routed worker and prevents a second repair writer
# from entering the worktree. The pack order's claim already fenced the route;
# this second claim is the worker boundary and is intentionally explicit.
if ! gc bd update "$BEAD_ID" --claim >/dev/null; then
    fail_state "worker could not claim source bead" || exit 1
fi

read_meta() {
    printf '%s' "$BEAD" | jq -r --arg key "$1" '.metadata[$key] // empty'
}

HOLD_CLASS="$(read_meta gc.candidate_review_hold_class)"
STATE="$(read_meta gc.candidate_review_state)"
OWNER="$(read_meta gc.candidate_review_owner)"
REPAIR_ROUTE="$(read_meta gc.candidate_review_repair_route)"
REVIEW_ROUTE="$(read_meta gc.candidate_review_review_route)"
TARGET_BRANCH="$(read_meta gc.candidate_review_target)"
SOURCE_BRANCH="$(read_meta gc.candidate_review_source)"
WORK_DIR="$(read_meta gc.work_dir)"
if [ "$HOLD_CLASS" != "mechanical" ] || { [ "$STATE" != "queued" ] && [ "$STATE" != "active" ]; }; then
    fail_state "hold is no longer an explicit queued mechanical candidate" || exit 1
fi
if [ -z "$OWNER" ] || [ -z "$REPAIR_ROUTE" ] || [ -z "$REVIEW_ROUTE" ] || [ -z "$TARGET_BRANCH" ] || [ -z "$SOURCE_BRANCH" ] || [ -z "$WORK_DIR" ]; then
    fail_state "candidate contract is missing owner, routes, source, target, or worktree" || exit 1
fi
if ! printf '%s' "$BEAD" | jq -e '.metadata | has("gc.candidate_review_residue") and has("gc.candidate_review_landed")' >/dev/null 2>&1; then
    fail_state "candidate contract is missing explicit residue and landed path lists" || exit 1
fi
if [ "$OWNER" != "$REPAIR_ROUTE" ]; then
    fail_state "candidate correction owner does not match repair route" || exit 1
fi

if ! git check-ref-format --branch "$SOURCE_BRANCH" >/dev/null 2>&1; then
    fail_state "candidate source is not a valid branch name" || exit 1
fi
if ! git check-ref-format --branch "$TARGET_BRANCH" >/dev/null 2>&1; then
    fail_state "candidate target is not a valid branch name" || exit 1
fi
if [ ! -d "$WORK_DIR" ]; then
    fail_state "candidate worktree does not exist: $WORK_DIR" || exit 1
fi
cd "$WORK_DIR"
if [ -n "$(git status --porcelain=v1)" ]; then
    fail_state "candidate worktree is dirty; preserving foreign or uncertain work" || exit 1
fi

RESIDUE_JSON="$(read_meta gc.candidate_review_residue)"
LANDED_JSON="$(read_meta gc.candidate_review_landed)"
RESIDUE_JSON="${RESIDUE_JSON:-[]}"
LANDED_JSON="${LANDED_JSON:-[]}"
validate_paths() {
    local label="$1" value="$2"
    if ! printf '%s' "$value" | jq -e 'type == "array" and all(.[]; type == "string" and length > 0 and (startswith("/") | not) and (contains("..") | not) and . != "." and . != ".git" and (startswith(".git/") | not))' >/dev/null 2>&1; then
        fail_state "$label contains invalid absolute, traversal, git-internal, or non-string path" || exit 1
    fi
}
validate_paths residue "$RESIDUE_JSON"
validate_paths landed "$LANDED_JSON"

if ! git fetch --prune origin "refs/heads/$TARGET_BRANCH:refs/remotes/origin/$TARGET_BRANCH" \
    "refs/heads/$SOURCE_BRANCH:refs/remotes/origin/$SOURCE_BRANCH" >/dev/null 2>&1; then
    fail_state "unable to fetch candidate and target refs from origin" || exit 1
fi
TARGET_REF="refs/remotes/origin/$TARGET_BRANCH"
if ! git show-ref --verify --quiet "$TARGET_REF"; then
    fail_state "fetched target ref is missing: $TARGET_BRANCH" || exit 1
fi
if ! git show-ref --verify --quiet "refs/remotes/origin/$SOURCE_BRANCH"; then
    fail_state "fetched candidate ref is missing: $SOURCE_BRANCH" || exit 1
fi

CURRENT_BRANCH="$(git branch --show-current)"
if [ "$CURRENT_BRANCH" != "$SOURCE_BRANCH" ]; then
    if git show-ref --verify --quiet "refs/heads/$SOURCE_BRANCH"; then
        if ! git switch "$SOURCE_BRANCH" >/dev/null 2>&1; then
            fail_state "candidate branch is owned by another worktree" || exit 1
        fi
    else
        if ! git switch --create "$SOURCE_BRANCH" "refs/remotes/origin/$SOURCE_BRANCH" >/dev/null 2>&1; then
            fail_state "could not enter candidate branch" || exit 1
        fi
    fi
fi

TARGET_COMMIT="$(git rev-parse "$TARGET_REF")"
if ! gc bd update "$BEAD_ID" --if-status in_progress --if-assignee "$GC_AGENT" \
    --set-metadata gc.candidate_review_state=active \
    --set-metadata gc.candidate_review_target_commit="$TARGET_COMMIT" \
    --set-metadata gc.candidate_review_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null; then
    fail_state "worker claim was lost before repair started" || exit 1
fi

remove_explicit_paths() {
    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [ -e "$path" ] || [ -L "$path" ]; then
            if [ -d "$path" ] && [ ! -L "$path" ]; then
                fail_state "declared residue is a directory, refusing recursive deletion: $path" || exit 1
            fi
            if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
                git rm -f -- "$path" >/dev/null
            else
                rm -f -- "$path"
            fi
        fi
    done < <(printf '%s' "$RESIDUE_JSON" | jq -r '.[]')
}
restore_explicit_paths() {
    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if ! git cat-file -e "$TARGET_REF:$path" >/dev/null 2>&1; then
            fail_state "declared already-landed path is absent from target: $path" || exit 1
        fi
        if ! git restore --source="$TARGET_REF" -- "$path"; then
            fail_state "could not omit already-landed path from candidate: $path" || exit 1
        fi
    done < <(printf '%s' "$LANDED_JSON" | jq -r '.[]')
}
remove_explicit_paths
restore_explicit_paths

if [ -n "$(git status --porcelain=v1)" ]; then
    git add -A
    if ! git diff --cached --quiet; then
        git commit -m "chore: repair candidate review hold" >/dev/null
    fi
fi
if ! git rebase "$TARGET_REF" >/dev/null 2>&1; then
    git rebase --abort >/dev/null 2>&1 || true
    fail_state "candidate cannot be rebased mechanically onto current target" || exit 1
fi

GATE_EVIDENCE=""
GATES_BASE_COMMIT="$(git rev-parse HEAD)"
run_gate() {
    local name="$1" command_value="$2"
    [ -n "$command_value" ] || return 0
    if ! sh -c "$command_value"; then
        fail_state "configured $name gate failed" || exit 1
    fi
    GATE_EVIDENCE="${GATE_EVIDENCE}${name}=passed;"
}
run_gate setup "${GC_CANDIDATE_REPAIR_SETUP_COMMAND:-}"
run_gate typecheck "${GC_CANDIDATE_REPAIR_TYPECHECK_COMMAND:-}"
run_gate lint "${GC_CANDIDATE_REPAIR_LINT_COMMAND:-}"
run_gate test "${GC_CANDIDATE_REPAIR_TEST_COMMAND:-}"
run_gate build "${GC_CANDIDATE_REPAIR_BUILD_COMMAND:-}"
if [ -z "$GATE_EVIDENCE" ]; then
    fail_state "no configured repair gates were supplied" || exit 1
fi
if [ -n "$(git status --porcelain=v1)" ] || [ "$(git rev-parse HEAD)" != "$GATES_BASE_COMMIT" ]; then
    fail_state "configured gates changed the candidate worktree; preserving the unreviewed changes" || exit 1
fi

# Do not publish if target moved during repair or gates. This is a fresh fetch,
# not a read of a local tracking ref that may be stale.
if ! git fetch origin "refs/heads/$TARGET_BRANCH:refs/remotes/origin/$TARGET_BRANCH" >/dev/null 2>&1; then
    fail_state "unable to refresh target before publication" || exit 1
fi
CURRENT_TARGET_COMMIT="$(git rev-parse "$TARGET_REF")"
if [ "$CURRENT_TARGET_COMMIT" != "$TARGET_COMMIT" ]; then
    fail_state "target moved during repair; candidate was not published" || exit 1
fi

REMOTE_BEFORE="$(git ls-remote origin "refs/heads/$SOURCE_BRANCH" | awk 'NR == 1 {print $1}')"
if [ -z "$REMOTE_BEFORE" ]; then
    fail_state "candidate remote branch disappeared before publication" || exit 1
fi
CANDIDATE_COMMIT="$(git rev-parse HEAD)"
if ! git push --force-with-lease="refs/heads/$SOURCE_BRANCH:$REMOTE_BEFORE" origin "HEAD:refs/heads/$SOURCE_BRANCH" >/dev/null 2>&1; then
    fail_state "candidate push lost its remote lease" || exit 1
fi

if ! gc bd update "$BEAD_ID" \
    --set-metadata gc.candidate_review_state=published_pending_review \
    --set-metadata gc.candidate_review_candidate_commit="$CANDIDATE_COMMIT" \
    --set-metadata gc.candidate_review_target_commit="$TARGET_COMMIT" \
    --set-metadata gc.candidate_review_gate_result=passed \
    --set-metadata gc.candidate_review_gate_evidence="$GATE_EVIDENCE" \
    --set-metadata gc.candidate_review_published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null; then
    echo "candidate-review-repair-worker: pushed $CANDIDATE_COMMIT but could not persist publication evidence" >&2
    exit 1
fi

if ! REVIEW_OUTPUT="$(gc sling "$REVIEW_ROUTE" "$BEAD_ID" --no-formula --reassign 2>&1)"; then
    gc bd update "$BEAD_ID" --set-metadata gc.candidate_review_last_error="review handoff failed: $REVIEW_OUTPUT" \
        --append-notes "Candidate is durable at $CANDIDATE_COMMIT; review handoff remains pending." >/dev/null
    echo "candidate-review-repair-worker: durable candidate $CANDIDATE_COMMIT awaits review handoff: $REVIEW_OUTPUT" >&2
    exit 1
fi
if ! gc bd update "$BEAD_ID" \
    --set-metadata gc.candidate_review_state=resubmitted \
    --set-metadata gc.candidate_review_review_submitted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --unset-metadata gc.candidate_review_last_error >/dev/null; then
    echo "candidate-review-repair-worker: review was routed but evidence update failed" >&2
    exit 1
fi
echo "candidate-review-repair-worker: published $CANDIDATE_COMMIT and resubmitted $BEAD_ID to $REVIEW_ROUTE"
