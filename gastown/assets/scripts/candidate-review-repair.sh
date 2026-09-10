#!/usr/bin/env bash
# candidate-review-repair — allocate durable repair tasks for mechanical holds.
#
# This coordinator never edits Git state, reassigns the source bead, or runs
# bead-authored commands. One exact metadata CAS allocates a generation; a
# deterministic external reference makes task creation crash-convergent.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
    echo "candidate-review-repair: jq is required" >&2
    exit 1
fi
if [ -z "${GC_RIG:-}" ] || ! [[ "$GC_RIG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "candidate-review-repair: a path-safe GC_RIG is required" >&2
    exit 1
fi

STORE_REF="rig:$GC_RIG"
CONTROL_KEY="gc.candidate_review_control"
WORKFLOW="mol-candidate-review-repair"

read_meta() {
    printf '%s' "$1" | jq -r --arg key "$2" '.metadata[$key] // empty'
}

all_beads() {
    local result
    result="$(gc bd list --all --limit=0 --json)" || return 1
    printf '%s' "$result" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
    printf '%s' "$result"
}

metadata_cas() {
    local id="$1" expected="$2" next="$3" result
    result="$(gc beads metadata-cas "$id" --store-ref "$STORE_REF" \
        --key "$CONTROL_KEY" --expected "$expected" --next "$next" --json)" || return 1
    printf '%s' "$result" | jq -r '.outcome // empty'
}

find_task() {
    local inventory="$1" external_ref="$2"
    printf '%s' "$inventory" | jq -c --arg ref "$external_ref" \
        '[.[] | select((.external_ref // "") == $ref)]'
}

route_generation() {
    local source="$1" source_id control state generation external_ref route review_route correction correction_b64
    local source_branch target_branch
    local next_control inventory matches count task_id task route_seen outcome metadata created dispatch_attempt dispatch_limit
    source_id="$(printf '%s' "$source" | jq -r '.id // empty')"
    control="$(read_meta "$source" "$CONTROL_KEY")"
    state=""
    if [ -n "$control" ]; then
        state="$(printf '%s' "$control" | jq -r '.state // empty' 2>/dev/null || true)"
    fi

    [ "$(read_meta "$source" gc.candidate_review_state)" = "actionable" ] || return 0
    [ "$(read_meta "$source" gc.candidate_review_hold_class)" = "mechanical" ] || return 0
    route="$(read_meta "$source" gc.candidate_review_repair_route)"
    review_route="$(read_meta "$source" gc.candidate_review_review_route)"
    correction="$(read_meta "$source" gc.candidate_review_correction)"
    source_branch="$(read_meta "$source" gc.candidate_review_source)"
    target_branch="$(read_meta "$source" gc.candidate_review_target)"
    [ -n "$source_id" ] && [[ "$source_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 0
    [ -n "$correction" ] && [ "${#correction}" -le 8192 ] || return 0
    [[ "$route" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$ ]] || return 0
    [[ "$review_route" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$ ]] || return 0
    [ "$(read_meta "$source" gc.candidate_review_owner)" = "$route" ] || return 0
    [[ "$source_branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$ ]] || return 0
    [[ "$target_branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$ ]] || return 0
    git check-ref-format --branch "$source_branch" >/dev/null 2>&1 || return 0
    git check-ref-format --branch "$target_branch" >/dev/null 2>&1 || return 0
    [ "$source_branch" != "$target_branch" ] || return 0
    correction_b64="$(jq -rn --arg value "$correction" '$value | @base64')"

    case "$state" in
        "")
            generation="$(printf '%s' "$source_id:$(date -u +%s):$$:$RANDOM" | shasum -a 256 | cut -c1-24)"
            external_ref="candidate-review-repair:$source_id:$generation"
            next_control="$(jq -cn --arg generation "$generation" --arg external_ref "$external_ref" \
                --arg route "$route" --arg review_route "$review_route" --arg source_branch "$source_branch" \
                --arg target_branch "$target_branch" --arg correction_b64 "$correction_b64" \
                '{schema:1,state:"allocating",generation:$generation,repair_attempt:1,repair_limit:1,dispatch_attempt:0,dispatch_limit:3,task_external_ref:$external_ref,repair_route:$route,review_route:$review_route,source_branch:$source_branch,target_branch:$target_branch,correction_b64:$correction_b64}')"
            outcome="$(metadata_cas "$source_id" "" "$next_control")" || {
                echo "candidate-review-repair: exact metadata CAS unavailable for $source_id; preserving hold" >&2
                return 1
            }
            [ "$outcome" = "swapped" ] || return 0
            control="$next_control"
            state="allocating"
            ;;
        allocating|routed|dispatching)
            ;;
        *)
            return 0
            ;;
    esac

    generation="$(printf '%s' "$control" | jq -r '.generation // empty')"
    external_ref="$(printf '%s' "$control" | jq -r '.task_external_ref // empty')"
    route="$(printf '%s' "$control" | jq -r '.repair_route // empty')"
    review_route="$(printf '%s' "$control" | jq -r '.review_route // empty')"
    [ -n "$generation" ] && [ -n "$external_ref" ] && [ -n "$route" ] && [ -n "$review_route" ] || {
        echo "candidate-review-repair: malformed control record for $source_id; preserving it" >&2
        return 1
    }
    [ "$route" = "$(read_meta "$source" gc.candidate_review_repair_route)" ] && \
        [ "$review_route" = "$(read_meta "$source" gc.candidate_review_review_route)" ] && \
        [ "$(printf '%s' "$control" | jq -r '.source_branch // empty')" = "$source_branch" ] && \
        [ "$(printf '%s' "$control" | jq -r '.target_branch // empty')" = "$target_branch" ] && \
        [ "$(printf '%s' "$control" | jq -r '.correction_b64 // empty')" = "$correction_b64" ] || {
        echo "candidate-review-repair: source contract changed for $source_id; preserving it" >&2
        return 1
    }

    inventory="$(all_beads)" || {
        echo "candidate-review-repair: cannot reconcile task inventory for $source_id" >&2
        return 1
    }
    matches="$(find_task "$inventory" "$external_ref")"
    count="$(printf '%s' "$matches" | jq 'length')"
    if [ "$count" -gt 1 ]; then
        echo "candidate-review-repair: ambiguous duplicate repair tasks for $source_id" >&2
        return 1
    fi
    if [ "$count" -eq 0 ]; then
        metadata="$(jq -cn --arg source "$source_id" --arg generation "$generation" \
            '{"gc.candidate_review_source_ref":$source,"gc.candidate_review_generation":$generation}')"
        if ! created="$(gc bd create --silent --parent "$source_id" --external-ref "$external_ref" \
            --metadata "$metadata" --title "Repair candidate review hold: $source_id" \
            --description "Execute the fixed Gas Town candidate-review repair workflow for source $source_id.")"; then
            echo "candidate-review-repair: task creation outcome is ambiguous for $source_id; will reconcile before retry" >&2
            return 1
        fi
        task_id="$(printf '%s' "$created" | tr -d '[:space:]')"
        [ -n "$task_id" ] || return 1
    else
        task_id="$(printf '%s' "$matches" | jq -r '.[0].id // empty')"
    fi

    task="$(gc bd show "$task_id" --json | jq -c 'if type == "array" and length == 1 then .[0] else empty end')"
    [ -n "$task" ] || return 1
    if [ "$(read_meta "$task" gc.candidate_review_source_ref)" != "$source_id" ] || \
        [ "$(read_meta "$task" gc.candidate_review_generation)" != "$generation" ]; then
        echo "candidate-review-repair: task identity mismatch for $source_id; preserving it" >&2
        return 1
    fi

    if [ "$state" = "allocating" ]; then
        next_control="$(printf '%s' "$control" | jq -c '.state="routed"')"
        outcome="$(metadata_cas "$source_id" "$control" "$next_control")" || return 1
        case "$outcome" in
            swapped|already_next) control="$next_control" ;;
            conflict) return 0 ;;
            *) return 1 ;;
        esac
    fi

    route_seen="$(read_meta "$task" gc.execution_routed_to)"
    if [ "$route_seen" = "$route" ]; then
        return 0
    fi
    if [ -n "$(printf '%s' "$task" | jq -r '.assignee // empty')" ]; then
        echo "candidate-review-repair: repair task $task_id has foreign ownership; preserving it" >&2
        return 1
    fi
    dispatch_attempt="$(printf '%s' "$control" | jq -r '.dispatch_attempt // empty')"
    dispatch_limit="$(printf '%s' "$control" | jq -r '.dispatch_limit // empty')"
    [[ "$dispatch_attempt" =~ ^[0-9]$ && "$dispatch_limit" =~ ^[1-9]$ ]] || return 1
    if [ "$dispatch_attempt" -ge "$dispatch_limit" ]; then
        next_control="$(printf '%s' "$control" | jq -c '.state="dispatch_exhausted"')"
        outcome="$(metadata_cas "$source_id" "$control" "$next_control")" || return 1
        case "$outcome" in
            swapped|already_next) ;;
            conflict) return 0 ;;
            *) return 1 ;;
        esac
        echo "candidate-review-repair: dispatch budget exhausted for $source_id" >&2
        return 1
    fi
    next_control="$(printf '%s' "$control" | jq -c '.state="dispatching" | .dispatch_attempt += 1')"
    outcome="$(metadata_cas "$source_id" "$control" "$next_control")" || return 1
    [ "$outcome" = "swapped" ] || return 0
    control="$next_control"
    gc sling "$route" "$task_id" --on "$WORKFLOW" \
        --var "source_ref=$source_id" --var "store_ref=$STORE_REF" \
        --var "expected_control=$control" --var "review_route=$review_route" >/dev/null
}

SOURCES="$(gc bd query --json --limit=0 'status!=closed')" || {
    echo "candidate-review-repair: unable to query candidate holds" >&2
    exit 1
}
printf '%s' "$SOURCES" | jq -e 'type == "array"' >/dev/null 2>&1 || exit 1
while IFS= read -r source; do
    route_generation "$source"
done < <(printf '%s' "$SOURCES" | jq -c '.[]')