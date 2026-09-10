#!/usr/bin/env bash
# candidate-review-repair-worker — deterministic git side of the pack loop.
#
# The model owns only the persisted exact correction. This worker validates the
# current repair token and repository boundary, serializes mutation in the Git
# common directory, touches only explicit paths, integrates the current target,
# runs configured gates, performs a normal fast-forward publication, and hands
# the durable candidate back to review.
set -euo pipefail

BEAD_ID="${1:-}"
EXPECTED_TOKEN="${GC_CANDIDATE_REPAIR_TOKEN:-}"
if [ -z "$BEAD_ID" ] || ! [[ "$BEAD_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "candidate-review-repair-worker: a path-safe bead id is required" >&2
    exit 1
fi
if [ -z "$EXPECTED_TOKEN" ]; then
    echo "candidate-review-repair-worker: GC_CANDIDATE_REPAIR_TOKEN is required" >&2
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

read_bead() {
    local result
    result="$(gc bd show "$BEAD_ID" --json)" || return 1
    printf '%s' "$result" | jq -e --arg bead_id "$BEAD_ID" \
        'type == "array" and length == 1 and .[0].id == $bead_id' >/dev/null 2>&1 || return 1
    printf '%s' "$result" | jq -c '.[0]'
}

read_meta() {
    printf '%s' "$1" | jq -r --arg key "$2" '.metadata[$key] // empty'
}

# Fail without mutation until the complete eligibility contract has been
# checked. This is what keeps human, external, stale, and malformed holds
# genuinely untouched even if a caller invokes the worker directly.
BEAD="$(read_bead)" || {
    echo "candidate-review-repair-worker: unable to read an unambiguous $BEAD_ID" >&2
    exit 1
}
STATUS="$(printf '%s' "$BEAD" | jq -r '.status // empty')"
ASSIGNEE="$(printf '%s' "$BEAD" | jq -r '.assignee // empty')"
HOLD_CLASS="$(read_meta "$BEAD" gc.candidate_review_hold_class)"
STATE="$(read_meta "$BEAD" gc.candidate_review_state)"
TOKEN="$(read_meta "$BEAD" gc.candidate_review_token)"
OWNER="$(read_meta "$BEAD" gc.candidate_review_owner)"
REPAIR_ROUTE="$(read_meta "$BEAD" gc.candidate_review_repair_route)"
REVIEW_ROUTE="$(read_meta "$BEAD" gc.candidate_review_review_route)"
TARGET_BRANCH="$(read_meta "$BEAD" gc.candidate_review_target)"
SOURCE_BRANCH="$(read_meta "$BEAD" gc.candidate_review_source)"
WORK_DIR="${GC_CANDIDATE_REPAIR_WORK_DIR:-}"
ATTEMPT="$(read_meta "$BEAD" gc.candidate_review_repair_attempt)"
MAX_ATTEMPTS="$(read_meta "$BEAD" gc.candidate_review_max_attempts)"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
if [ "$STATUS" != "in_progress" ]; then
    echo "candidate-review-repair-worker: candidate is not an in-progress repair" >&2
    exit 1
fi
if [ "$HOLD_CLASS" != "mechanical" ] || { [ "$STATE" != "queued" ] && [ "$STATE" != "active" ]; }; then
    echo "candidate-review-repair-worker: hold is not an explicit queued mechanical candidate" >&2
    exit 1
fi
if [ "$TOKEN" != "$EXPECTED_TOKEN" ] || [ "$ASSIGNEE" != "$GC_AGENT" ]; then
    echo "candidate-review-repair-worker: repair token or owner is stale" >&2
    exit 1
fi
if [ -z "$OWNER" ] || [ "$OWNER" != "$REPAIR_ROUTE" ] || [ -z "$REVIEW_ROUTE" ] || \
    [ -z "$TARGET_BRANCH" ] || [ -z "$SOURCE_BRANCH" ]; then
    echo "candidate-review-repair-worker: candidate contract is incomplete or inconsistent" >&2
    exit 1
fi
if [ -z "$WORK_DIR" ]; then
    echo "candidate-review-repair-worker: trusted formula worktree is missing" >&2
    exit 1
fi
case "$WORK_DIR" in
    /*) ;;
    *) echo "candidate-review-repair-worker: trusted formula worktree must be absolute" >&2; exit 1 ;;
esac
if ! [[ "$ATTEMPT" =~ ^[1-9][0-9]*$ && "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || [ "$ATTEMPT" -gt "$MAX_ATTEMPTS" ]; then
    echo "candidate-review-repair-worker: repair attempt is invalid or exhausted" >&2
    exit 1
fi
if ! printf '%s' "$BEAD" | jq -e '.metadata | has("gc.candidate_review_residue") and has("gc.candidate_review_landed")' >/dev/null 2>&1; then
    echo "candidate-review-repair-worker: candidate contract lacks explicit path lists" >&2
    exit 1
fi
if ! git check-ref-format --branch "$SOURCE_BRANCH" >/dev/null 2>&1 || \
    ! git check-ref-format --branch "$TARGET_BRANCH" >/dev/null 2>&1 || \
    [ "$SOURCE_BRANCH" = "$TARGET_BRANCH" ]; then
    echo "candidate-review-repair-worker: source and target must be distinct valid branches" >&2
    exit 1
fi
if [ ! -d "$WORK_DIR" ]; then
    echo "candidate-review-repair-worker: candidate worktree does not exist: $WORK_DIR" >&2
    exit 1
fi

cd "$WORK_DIR"
WORK_TOP="$(pwd -P)"
GIT_TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "candidate-review-repair-worker: work directory is not a Git worktree" >&2
    exit 1
}
GIT_TOP="$(cd "$GIT_TOP" && pwd -P)"
if [ "$WORK_TOP" != "$GIT_TOP" ]; then
    echo "candidate-review-repair-worker: work directory must be the Git top-level" >&2
    exit 1
fi
CURRENT_BRANCH="$(git branch --show-current)"
if [ "$CURRENT_BRANCH" != "$SOURCE_BRANCH" ]; then
    echo "candidate-review-repair-worker: trusted worktree is not on the declared source branch" >&2
    exit 1
fi
if [ -n "$(git status --porcelain=v1)" ]; then
    echo "candidate-review-repair-worker: candidate worktree is dirty; preserving foreign or uncertain work" >&2
    exit 1
fi

# Serialize all Git mutation for this repository. A dead same-host owner can be
# reclaimed; a live or remote-host owner is preserved rather than guessed dead.
GIT_COMMON="$(git rev-parse --git-common-dir)"
case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$WORK_TOP/$GIT_COMMON" ;; esac
GIT_COMMON="$(cd "$GIT_COMMON" && pwd -P)"
LOCK_ROOT="$GIT_COMMON/gc-candidate-review-locks"
# One writer per repository. Different beads may target the same worktree or
# source branch, so a bead-scoped lock would not prevent cross-bead Git races.
LOCK_FILE="$LOCK_ROOT/writer"
LOCK_HOST="$(hostname)"
if [ -L "$LOCK_ROOT" ] || { [ -e "$LOCK_ROOT" ] && [ ! -d "$LOCK_ROOT" ]; }; then
    echo "candidate-review-repair-worker: repair lock directory is not a local directory" >&2
    exit 1
fi
mkdir -p "$LOCK_ROOT"
if [ -L "$LOCK_ROOT" ] || [ "$(cd "$LOCK_ROOT" && pwd -P)" != "$LOCK_ROOT" ]; then
    echo "candidate-review-repair-worker: repair lock directory resolves outside the Git repository" >&2
    exit 1
fi
LOCK_TEMP="$(mktemp "$LOCK_ROOT/.writer.XXXXXX")" || {
    echo "candidate-review-repair-worker: unable to create repair lock temporary file" >&2
    exit 1
}
if [ -L "$LOCK_TEMP" ] || [ ! -f "$LOCK_TEMP" ] ||
    ! printf '%s\n%s\n%s\n' "$LOCK_HOST" "$$" "$EXPECTED_TOKEN" >"$LOCK_TEMP"; then
    rm -f -- "$LOCK_TEMP"
    echo "candidate-review-repair-worker: repair lock temporary file is unsafe" >&2
    exit 1
fi
if [ -L "$LOCK_FILE" ]; then
    rm -f -- "$LOCK_TEMP"
    echo "candidate-review-repair-worker: repair lock is a symlink" >&2
    exit 1
fi
if ! ln "$LOCK_TEMP" "$LOCK_FILE" 2>/dev/null; then
    lock_host=""
    lock_pid=""
    lock_token=""
    if [ -f "$LOCK_FILE" ] && [ ! -L "$LOCK_FILE" ]; then
        {
            IFS= read -r lock_host || true
            IFS= read -r lock_pid || true
            IFS= read -r lock_token || true
        } <"$LOCK_FILE"
    fi
    if [ "$lock_host" = "$LOCK_HOST" ] && [[ "$lock_pid" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
        rm -f -- "$LOCK_FILE"
        if ! ln "$LOCK_TEMP" "$LOCK_FILE" 2>/dev/null; then
            rm -f -- "$LOCK_TEMP"
            echo "candidate-review-repair-worker: repair lock could not be reclaimed" >&2
            exit 1
        fi
    else
        rm -f -- "$LOCK_TEMP"
        echo "candidate-review-repair-worker: another repair writer owns $BEAD_ID" >&2
        exit 1
    fi
fi
rm -f -- "$LOCK_TEMP"
cleanup_lock() {
    local lock_host="" lock_pid="" lock_token=""
    if [ -f "$LOCK_FILE" ] && [ ! -L "$LOCK_FILE" ]; then
        {
            IFS= read -r lock_host || true
            IFS= read -r lock_pid || true
            IFS= read -r lock_token || true
        } <"$LOCK_FILE"
    fi
    if [ "$lock_host" = "$LOCK_HOST" ] && [ "$lock_pid" = "$$" ] && [ "$lock_token" = "$EXPECTED_TOKEN" ]; then
        rm -f -- "$LOCK_FILE"
    fi
}
trap cleanup_lock EXIT INT TERM

fresh_guarded_update() {
    local fresh fresh_token fresh_status fresh_assignee fresh_hold_class fresh_state
    fresh="$(read_bead)" || return 1
    fresh_token="$(read_meta "$fresh" gc.candidate_review_token)"
    [ "$fresh_token" = "$EXPECTED_TOKEN" ] || return 13
    fresh_status="$(printf '%s' "$fresh" | jq -r '.status // empty')"
    fresh_assignee="$(printf '%s' "$fresh" | jq -r '.assignee // empty')"
    fresh_hold_class="$(read_meta "$fresh" gc.candidate_review_hold_class)"
    fresh_state="$(read_meta "$fresh" gc.candidate_review_state)"
    [ "$fresh_status" = "in_progress" ] || return 13
    [ "$fresh_assignee" = "$GC_AGENT" ] || return 13
    [ "$fresh_hold_class" = "mechanical" ] || return 13
    [ "$fresh_state" = "queued" ] || [ "$fresh_state" = "active" ] || return 13
    gc bd update "$BEAD_ID" --if-status "$fresh_status" --if-assignee "$fresh_assignee" "$@"
}

token_guarded_update() {
    local fresh fresh_token fresh_status fresh_assignee fresh_hold_class
    fresh="$(read_bead)" || return 1
    fresh_token="$(read_meta "$fresh" gc.candidate_review_token)"
    [ "$fresh_token" = "$EXPECTED_TOKEN" ] || return 13
    fresh_status="$(printf '%s' "$fresh" | jq -r '.status // empty')"
    fresh_assignee="$(printf '%s' "$fresh" | jq -r '.assignee // empty')"
    fresh_hold_class="$(read_meta "$fresh" gc.candidate_review_hold_class)"
    [ "$fresh_status" != "closed" ] || return 13
    [ -n "$fresh_assignee" ] || return 13
    [ "$fresh_hold_class" = "mechanical" ] || return 13
    gc bd update "$BEAD_ID" --if-status "$fresh_status" --if-assignee "$fresh_assignee" "$@"
}

fail_state() {
    local reason="$1"
    if ! fresh_guarded_update \
        --set-metadata gc.candidate_review_state=repair_failed \
        --set-metadata gc.candidate_review_last_error="$reason" \
        --append-notes "Candidate repair stopped safely: $reason" >/dev/null; then
        echo "candidate-review-repair-worker: newer ownership prevented stale failure evidence" >&2
    fi
    echo "candidate-review-repair-worker: $reason" >&2
    return 1
}

validate_path_metadata() {
    local key="$1" label="$2"
    if ! printf '%s' "$BEAD" | jq -e --arg key "$key" '
        def decode_path_list:
            if type == "array" then .
            elif type == "string" then (try fromjson catch null)
            else null
            end;
        (.metadata[$key]? // null | decode_path_list) |
        type == "array" and all(.[];
            type == "string" and length > 0 and
            (explode | all(.[]; . >= 32 and . != 127)) and
            (startswith("/") | not) and
            (endswith("/") | not) and
            ((split("/")) as $parts | all($parts[]; . != "" and . != "." and . != "..")) and
            . != ".git" and (startswith(".git/") | not)
        )
    ' >/dev/null 2>&1; then
        echo "candidate-review-repair-worker: $label contains an invalid, control-character, absolute, traversal, or git-internal path" >&2
        exit 1
    fi
}
validate_path_metadata gc.candidate_review_residue residue
validate_path_metadata gc.candidate_review_landed landed
if ! printf '%s' "$BEAD" | jq -e '
    def decode_path_list:
        if type == "array" then .
        elif type == "string" then (try fromjson catch null)
        else null
        end;
    .metadata as $metadata |
    (($metadata["gc.candidate_review_residue"] // "[]" | decode_path_list) +
        ($metadata["gc.candidate_review_landed"] // "[]" | decode_path_list)) as $paths |
    ($paths | unique | length) == ($paths | length)
' >/dev/null 2>&1; then
    echo "candidate-review-repair-worker: residue and landed path lists overlap" >&2
    exit 1
fi
RESIDUE_JSON="$(printf '%s' "$BEAD" | jq -c '
    .metadata["gc.candidate_review_residue"] | if type == "string" then fromjson else . end
')"
LANDED_JSON="$(printf '%s' "$BEAD" | jq -c '
    .metadata["gc.candidate_review_landed"] | if type == "string" then fromjson else . end
')"

has_symlink_component() {
    local path="$1" rest="$1" prefix="" component
    while :; do
        component="${rest%%/*}"
        [ -n "$prefix" ] && prefix="$prefix/$component" || prefix="$component"
        [ -L "$prefix" ] && return 0
        [ "$rest" = "$component" ] && break
        rest="${rest#*/}"
    done
    return 1
}
check_local_path_safety() {
    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if has_symlink_component "$path"; then
            echo "candidate-review-repair-worker: declared path traverses a symlink: $path" >&2
            exit 1
        fi
        if [ -d "$path" ] && [ ! -L "$path" ]; then
            echo "candidate-review-repair-worker: declared path is a directory: $path" >&2
            exit 1
        fi
        if { [ -e "$path" ] || [ -L "$path" ]; } && [ ! -f "$path" ]; then
            echo "candidate-review-repair-worker: declared path is not a regular file: $path" >&2
            exit 1
        fi
    done
}
check_target_path_safety() {
    local label="$1" paths_json="$2" path prefix object_type mode i last path_absent
    local -a components
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        IFS='/' read -r -a components <<< "$path"
        prefix=""
        path_absent=0
        last=$((${#components[@]} - 1))
        for i in "${!components[@]}"; do
            [ -n "$prefix" ] && prefix="$prefix/${components[$i]}" || prefix="${components[$i]}"
            object_type="$(git cat-file -t "$TARGET_REF:$prefix" 2>/dev/null || true)"
            if [ "$i" -lt "$last" ]; then
                if [ -z "$object_type" ] && [ "$label" = "residue" ]; then
                    path_absent=1
                    break
                fi
                if [ "$object_type" != "tree" ]; then
                    echo "candidate-review-repair-worker: declared $label target path has an unsafe symlink or non-directory ancestor: $path" >&2
                    exit 1
                fi
                continue
            fi
            if [ -z "$object_type" ]; then
                [ "$label" = "residue" ] && { path_absent=1; break; }
                echo "candidate-review-repair-worker: declared already-landed target path is absent: $path" >&2
                exit 1
            fi
            if [ "$object_type" != "blob" ]; then
                echo "candidate-review-repair-worker: declared $label target path is not a regular file: $path" >&2
                exit 1
            fi
            mode="$(git ls-tree -r "$TARGET_REF" -- "$path" | awk 'NR == 1 {print $1}')"
            case "$mode" in
                100644|100755) ;;
                120000)
                    echo "candidate-review-repair-worker: declared $label target path is a symlink: $path" >&2
                    exit 1
                    ;;
                *)
                    echo "candidate-review-repair-worker: declared $label target path has an unsafe file mode: $path" >&2
                    exit 1
                    ;;
            esac
        done
        [ "$path_absent" -eq 0 ] || continue
    done < <(printf '%s' "$paths_json" | jq -r '.[]')
}

check_local_path_safety < <(printf '%s\n%s' "$RESIDUE_JSON" "$LANDED_JSON" | jq -sr 'add | unique[]')

if ! git fetch origin "refs/heads/$TARGET_BRANCH:refs/remotes/origin/$TARGET_BRANCH" \
    "refs/heads/$SOURCE_BRANCH:refs/remotes/origin/$SOURCE_BRANCH" >/dev/null 2>&1; then
    echo "candidate-review-repair-worker: unable to fetch candidate and target refs from origin" >&2
    exit 1
fi
TARGET_REF="refs/remotes/origin/$TARGET_BRANCH"
SOURCE_REF="refs/remotes/origin/$SOURCE_BRANCH"
if ! git show-ref --verify --quiet "$TARGET_REF" || ! git show-ref --verify --quiet "$SOURCE_REF"; then
    echo "candidate-review-repair-worker: fetched candidate or target ref is missing" >&2
    exit 1
fi
check_target_path_safety residue "$RESIDUE_JSON"
check_target_path_safety landed "$LANDED_JSON"

if ! git merge-base --is-ancestor "$SOURCE_REF" HEAD; then
    echo "candidate-review-repair-worker: local candidate does not descend from the observed remote candidate" >&2
    exit 1
fi
TARGET_COMMIT="$(git rev-parse "$TARGET_REF")"

CURRENT_BEAD="$(read_bead)" || {
    echo "candidate-review-repair-worker: unable to re-read candidate before mutation" >&2
    exit 1
}
if [ "$(printf '%s' "$CURRENT_BEAD" | jq -S -c .)" != "$(printf '%s' "$BEAD" | jq -S -c .)" ]; then
    echo "candidate-review-repair-worker: candidate contract changed during preflight" >&2
    exit 1
fi
if ! fresh_guarded_update \
    --set-metadata gc.candidate_review_state=active \
    --set-metadata gc.candidate_review_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null; then
    echo "candidate-review-repair-worker: worker ownership changed before repair started" >&2
    exit 1
fi

remove_explicit_paths() {
    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if has_symlink_component "$path"; then
            fail_state "declared residue traverses a symlink: $path" || exit 1
        fi
        if [ -e "$path" ] || [ -L "$path" ]; then
            if [ -d "$path" ] && [ ! -L "$path" ]; then
                fail_state "declared residue is a directory, refusing recursive deletion: $path" || exit 1
            fi
            rm -f -- "$path"
        fi
    done < <(printf '%s' "$RESIDUE_JSON" | jq -r '.[]')
}
restore_explicit_paths() {
    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if has_symlink_component "$path"; then
            fail_state "declared landed path traverses a symlink: $path" || exit 1
        fi
        git cat-file -e "$TARGET_REF:$path" >/dev/null 2>&1 || {
            fail_state "declared already-landed path is absent from target: $path" || exit 1
        }
        git restore --source="$TARGET_REF" -- "$path" || {
            fail_state "could not omit already-landed path from candidate: $path" || exit 1
        }
    done < <(printf '%s' "$LANDED_JSON" | jq -r '.[]')
}
remove_explicit_paths
restore_explicit_paths
while IFS= read -r path; do
    [ -n "$path" ] || continue
    git add -A -- "$path"
done < <(printf '%s\n%s' "$RESIDUE_JSON" "$LANDED_JSON" | jq -sr 'add | unique[]')
if ! git diff --cached --quiet; then
    git commit -m "chore: repair candidate review hold" >/dev/null
fi
if [ -n "$(git status --porcelain=v1)" ]; then
    fail_state "undeclared worktree changes appeared during repair; preserving them" || exit 1
fi
if ! git merge --no-edit "$TARGET_REF" >/dev/null 2>&1; then
    git merge --abort >/dev/null 2>&1 || true
    fail_state "candidate cannot mechanically integrate the current target" || exit 1
fi

GATE_EVIDENCE=""
GATES_BASE_COMMIT="$(git rev-parse HEAD)"
run_gate() {
    local name="$1" command_value="$2"
    [ -n "$command_value" ] || return 0
    sh -c "$command_value" || {
        fail_state "configured $name gate failed" || exit 1
    }
    GATE_EVIDENCE="${GATE_EVIDENCE}${name}=passed;"
}
# This invariant belongs to the worker, so a direct invocation cannot bypass
# the minimum repository sanity check. Additional gates are operator-owned
# process configuration passed by the formula; bead metadata is never used as
# executable input.
run_gate diff-check "git diff --check"
run_gate setup "${GC_CANDIDATE_REPAIR_SETUP_COMMAND:-}"
run_gate typecheck "${GC_CANDIDATE_REPAIR_TYPECHECK_COMMAND:-}"
run_gate lint "${GC_CANDIDATE_REPAIR_LINT_COMMAND:-}"
run_gate test "${GC_CANDIDATE_REPAIR_TEST_COMMAND:-}"
run_gate build "${GC_CANDIDATE_REPAIR_BUILD_COMMAND:-}"
if [ -n "$(git status --porcelain=v1)" ] || [ "$(git rev-parse HEAD)" != "$GATES_BASE_COMMIT" ]; then
    fail_state "configured gates changed the candidate worktree; preserving the unreviewed changes" || exit 1
fi

if ! git fetch origin "refs/heads/$TARGET_BRANCH:refs/remotes/origin/$TARGET_BRANCH" >/dev/null 2>&1; then
    fail_state "unable to refresh target before publication" || exit 1
fi
CURRENT_TARGET_COMMIT="$(git rev-parse "$TARGET_REF")"
if [ "$CURRENT_TARGET_COMMIT" != "$TARGET_COMMIT" ]; then
    fail_state "target moved during repair; candidate was not published" || exit 1
fi
REMOTE_BEFORE="$(git ls-remote origin "refs/heads/$SOURCE_BRANCH" | awk 'NR == 1 {print $1}')"
if [ -z "$REMOTE_BEFORE" ] || [ "$REMOTE_BEFORE" != "$(git rev-parse "$SOURCE_REF")" ]; then
    fail_state "candidate remote moved or disappeared before publication" || exit 1
fi
CANDIDATE_COMMIT="$(git rev-parse HEAD)"
if ! git merge-base --is-ancestor "$REMOTE_BEFORE" "$CANDIDATE_COMMIT"; then
    fail_state "repaired candidate is not a fast-forward of the remote candidate" || exit 1
fi
if ! git push origin "HEAD:refs/heads/$SOURCE_BRANCH" >/dev/null 2>&1; then
    fail_state "candidate publication was not a normal fast-forward" || exit 1
fi

if ! fresh_guarded_update \
    --set-metadata gc.candidate_review_state=review_queued \
    --set-metadata gc.candidate_review_candidate_commit="$CANDIDATE_COMMIT" \
    --set-metadata gc.candidate_review_target_commit="$TARGET_COMMIT" \
    --set-metadata gc.candidate_review_gate_result=passed \
    --set-metadata gc.candidate_review_gate_evidence="$GATE_EVIDENCE" \
    --set-metadata gc.candidate_review_published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --set-metadata gc.candidate_review_review_queued_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null; then
    echo "candidate-review-repair-worker: pushed $CANDIDATE_COMMIT but ownership changed before evidence persisted" >&2
    exit 1
fi
if ! REVIEW_OUTPUT="$(gc sling "$REVIEW_ROUTE" "$BEAD_ID" --no-formula --reassign 2>&1)"; then
    fresh_guarded_update \
        --set-metadata gc.candidate_review_state=published_pending_review \
        --set-metadata gc.candidate_review_last_error="review handoff failed: $REVIEW_OUTPUT" \
        --append-notes "Candidate is durable at $CANDIDATE_COMMIT; review handoff remains pending." >/dev/null || true
    echo "candidate-review-repair-worker: durable candidate $CANDIDATE_COMMIT awaits review handoff: $REVIEW_OUTPUT" >&2
    exit 1
fi
if ! token_guarded_update \
    --set-metadata gc.candidate_review_state=resubmitted \
    --set-metadata gc.candidate_review_review_submitted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --unset-metadata gc.candidate_review_last_error >/dev/null; then
    echo "candidate-review-repair-worker: review was routed; newer ownership prevented stale evidence" >&2
fi
echo "candidate-review-repair-worker: published $CANDIDATE_COMMIT and resubmitted $BEAD_ID to $REVIEW_ROUTE"
