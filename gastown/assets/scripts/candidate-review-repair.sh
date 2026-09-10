#!/usr/bin/env bash
# candidate-review-repair — route explicit mechanical review holds.
#
# This is Gas Town pack policy, not SDK decision logic. A bead is eligible only
# when its owner has persisted an exact correction, both repair/review routes,
# source/target identity, configured gates, and hold_class=mechanical. All other
# holds are deliberately untouched. A unique temporary assignee is the CAS
# token that prevents concurrent order executions from dispatching twice.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
    echo "candidate-review-repair: jq is required" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="$SCRIPT_DIR/candidate-review-repair-worker.sh"
if [ ! -x "$WORKER" ]; then
    echo "candidate-review-repair: worker is missing or not executable: $WORKER" >&2
    exit 1
fi

BEADS_JSON=""
if ! BEADS_JSON="$(gc bd query --json --limit=0 'status!=closed')"; then
    echo "candidate-review-repair: unable to query open candidate holds" >&2
    exit 1
fi
if ! printf '%s' "$BEADS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "candidate-review-repair: gc bd query returned malformed JSON" >&2
    exit 1
fi

read_meta() {
    local bead_json="$1" key="$2"
    printf '%s' "$bead_json" | jq -r --arg key "$key" '.metadata[$key] // empty'
}

is_stale() {
    local timestamp="$1" max_age="${GC_CANDIDATE_REPAIR_STALE_SECONDS:-900}"
    [[ "$max_age" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s' "$timestamp" | jq -eR --argjson max_age "$max_age" '
        (try fromdateiso8601 catch 0) as $then |
        $then > 0 and (now - $then) >= $max_age
    ' >/dev/null 2>&1
}

fresh_guarded_update() {
    local id="$1" token="$2"
    shift 2
    local fresh fresh_token status assignee
    fresh="$(gc bd show "$id" --json)" || return 1
    fresh_token="$(printf '%s' "$fresh" | jq -r '.[0].metadata["gc.candidate_review_token"] // empty')"
    [ "$fresh_token" = "$token" ] || return 13
    status="$(printf '%s' "$fresh" | jq -r '.[0].status // empty')"
    assignee="$(printf '%s' "$fresh" | jq -r '.[0].assignee // empty')"
    gc bd update "$id" --if-status "$status" --if-assignee "$assignee" "$@"
}

route_review() {
    local bead_json="$1" id status assignee state route timestamp claim_token output rc
    id="$(printf '%s' "$bead_json" | jq -r '.id // empty')"
    status="$(printf '%s' "$bead_json" | jq -r '.status // empty')"
    assignee="$(printf '%s' "$bead_json" | jq -r '.assignee // empty')"
    state="$(read_meta "$bead_json" gc.candidate_review_state)"
    route="$(read_meta "$bead_json" gc.candidate_review_review_route)"
    [ -n "$id" ] && [ -n "$assignee" ] && [ -n "$route" ] || return 0
    [ "$(read_meta "$bead_json" gc.candidate_review_hold_class)" = "mechanical" ] || return 0

    case "$state" in
        published_pending_review)
            ;;
        review_queued)
            timestamp="$(read_meta "$bead_json" gc.candidate_review_review_queued_at)"
            is_stale "$timestamp" || return 0
            ;;
        *)
            return 0
            ;;
    esac

    claim_token="candidate-review:$id:$(date -u +%Y%m%dT%H%M%SZ):$$:$RANDOM"
    if gc bd update "$id" --if-status "$status" --if-assignee "$assignee" \
        --status in_progress --assignee "$claim_token" \
        --set-metadata gc.candidate_review_state=review_queued \
        --set-metadata gc.candidate_review_token="$claim_token" \
        --set-metadata gc.candidate_review_review_queued_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null; then
        :
    else
        rc=$?
        [ "$rc" -eq 13 ] && return 0
        echo "candidate-review-repair: failed to claim review handoff for $id (exit $rc)" >&2
        return 1
    fi
    if ! output="$(gc sling "$route" "$id" --no-formula --reassign 2>&1)"; then
        fresh_guarded_update "$id" "$claim_token" \
            --set-metadata gc.candidate_review_state=published_pending_review \
            --set-metadata gc.candidate_review_last_error="review handoff failed: $output" \
            --append-notes "Candidate is durable; review handoff remains pending." >/dev/null || true
        echo "candidate-review-repair: $id review handoff failed: $output" >&2
        return 1
    fi
    if ! fresh_guarded_update "$id" "$claim_token" \
        --set-metadata gc.candidate_review_state=resubmitted \
        --set-metadata gc.candidate_review_review_submitted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --unset-metadata gc.candidate_review_last_error >/dev/null; then
        echo "candidate-review-repair: $id review was routed; newer ownership prevented stale evidence" >&2
    fi
    echo "candidate-review-repair: resubmitted $id to $route"
}

route_repair() {
    local bead_json="$1" id status assignee state timestamp owner correction route workflow review_route target source residue landed
    local setup typecheck lint test_command build attempt max_attempts next claim_token output rc
    id="$(printf '%s' "$bead_json" | jq -r '.id // empty')"
    status="$(printf '%s' "$bead_json" | jq -r '.status // empty')"
    assignee="$(printf '%s' "$bead_json" | jq -r '.assignee // empty')"
    state="$(read_meta "$bead_json" gc.candidate_review_state)"

    case "$state" in
        actionable|repair_failed)
            ;;
        queued)
            timestamp="$(read_meta "$bead_json" gc.candidate_review_repair_queued_at)"
            is_stale "$timestamp" || return 0
            ;;
        active)
            timestamp="$(read_meta "$bead_json" gc.candidate_review_started_at)"
            is_stale "$timestamp" || return 0
            ;;
        *)
            return 0
            ;;
    esac

    [ "$status" = "open" ] || [ "$status" = "in_progress" ] || [ "$status" = "blocked" ] || return 0
    [ -n "$id" ] && [ -n "$assignee" ] || return 0
    [ "$(read_meta "$bead_json" gc.candidate_review_hold_class)" = "mechanical" ] || return 0

    owner="$(read_meta "$bead_json" gc.candidate_review_owner)"
    correction="$(read_meta "$bead_json" gc.candidate_review_correction)"
    route="$(read_meta "$bead_json" gc.candidate_review_repair_route)"
    workflow="$(read_meta "$bead_json" gc.candidate_review_repair_workflow)"
    review_route="$(read_meta "$bead_json" gc.candidate_review_review_route)"
    target="$(read_meta "$bead_json" gc.candidate_review_target)"
    source="$(read_meta "$bead_json" gc.candidate_review_source)"
    residue="$(read_meta "$bead_json" gc.candidate_review_residue)"
    landed="$(read_meta "$bead_json" gc.candidate_review_landed)"
    # Gate commands are operator-owned process configuration, never bead data.
    # A bead can request a repair but cannot inject an unattended shell command.
    setup="${GC_CANDIDATE_REPAIR_SETUP_COMMAND:-}"
    typecheck="${GC_CANDIDATE_REPAIR_TYPECHECK_COMMAND:-}"
    lint="${GC_CANDIDATE_REPAIR_LINT_COMMAND:-}"
    test_command="${GC_CANDIDATE_REPAIR_TEST_COMMAND:-git diff --check}"
    build="${GC_CANDIDATE_REPAIR_BUILD_COMMAND:-}"
    if [ -z "$owner" ] || [ "$owner" != "$route" ] || [ -z "$correction" ] || [ -z "$route" ] || \
        [ -z "$workflow" ] || [ -z "$review_route" ] || [ -z "$target" ] || [ -z "$source" ] || \
        [ -z "$residue" ] || [ -z "$landed" ]; then
        echo "candidate-review-repair: $id missing or inconsistent explicit contract; preserving hold" >&2
        return 0
    fi

    attempt="$(read_meta "$bead_json" gc.candidate_review_repair_attempt)"
    max_attempts="$(read_meta "$bead_json" gc.candidate_review_max_attempts)"
    attempt="${attempt:-0}"
    max_attempts="${max_attempts:-3}"
    if ! [[ "$attempt" =~ ^[0-9]+$ && "$max_attempts" =~ ^[1-9][0-9]*$ ]]; then
        echo "candidate-review-repair: $id has invalid attempt budget; preserving hold" >&2
        return 0
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
        if gc bd update "$id" --if-status "$status" --if-assignee "$assignee" \
            --set-metadata gc.candidate_review_state=exhausted \
            --set-metadata gc.candidate_review_last_error="repair attempt budget exhausted ($attempt/$max_attempts)" >/dev/null; then
            :
        else
            rc=$?
            [ "$rc" -eq 13 ] || return 1
        fi
        echo "candidate-review-repair: exhausted $id after $attempt/$max_attempts attempts" >&2
        return 0
    fi
    next=$((attempt + 1))
    claim_token="candidate-repair:$id:$next:$(date -u +%Y%m%dT%H%M%SZ):$$:$RANDOM"

    if gc bd update "$id" --if-status "$status" --if-assignee "$assignee" \
        --status in_progress --assignee "$claim_token" \
        --set-metadata gc.candidate_review_state=queued \
        --set-metadata gc.candidate_review_repair_attempt="$next" \
        --set-metadata gc.candidate_review_token="$claim_token" \
        --set-metadata gc.candidate_review_repair_queued_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --set-metadata gc.candidate_review_repair_owner="$owner" >/dev/null; then
        :
    else
        rc=$?
        [ "$rc" -eq 13 ] && return 0
        echo "candidate-review-repair: failed to claim $id (exit $rc)" >&2
        return 1
    fi

    if ! output="$(gc sling "$route" "$id" --on "$workflow" --reassign \
        --var "repair_script=$WORKER" --var "repair_token=$claim_token" \
        --var "setup_command=$setup" --var "typecheck_command=$typecheck" \
        --var "lint_command=$lint" --var "test_command=$test_command" \
        --var "build_command=$build" 2>&1)"; then
        fresh_guarded_update "$id" "$claim_token" \
            --set-metadata gc.candidate_review_state=repair_failed \
            --set-metadata gc.candidate_review_last_error="repair dispatch failed: $output" \
            --append-notes "Candidate repair dispatch failed; retry remains bounded." >/dev/null || true
        echo "candidate-review-repair: $id dispatch failed: $output" >&2
        return 1
    fi
    echo "candidate-review-repair: queued $id attempt $next via $route ($workflow)"
}

while IFS= read -r bead_json; do
    [ -n "$bead_json" ] || continue
    state="$(read_meta "$bead_json" gc.candidate_review_state)"
    case "$state" in
        published_pending_review|review_queued) route_review "$bead_json" ;;
        *) route_repair "$bead_json" ;;
    esac
done < <(printf '%s' "$BEADS_JSON" | jq -c '.[]')
