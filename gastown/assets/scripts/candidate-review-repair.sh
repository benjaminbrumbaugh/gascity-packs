#!/usr/bin/env bash
# candidate-review-repair — route explicit mechanical review holds.
#
# This is Gas Town pack policy, not SDK decision logic. A bead is eligible only
# when its owner has persisted an exact correction, both repair/review routes,
# source/target identity, and hold_class=mechanical. All other holds are
# deliberately untouched. The status+assignee precondition is the single
# writer claim; no local status/lock file is used.
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

route_review() {
    local id="$1" route="$2"
    local output
    if ! output="$(gc sling "$route" "$id" --no-formula --reassign 2>&1)"; then
        gc bd update "$id" \
            --set-metadata gc.candidate_review_last_error="review handoff failed: $output" \
            --append-notes "Candidate repair published a durable candidate but review handoff failed; retry is pending." >/dev/null
        echo "candidate-review-repair: $id review handoff failed: $output" >&2
        return 1
    fi
    if ! gc bd update "$id" \
        --set-metadata gc.candidate_review_state=resubmitted \
        --set-metadata gc.candidate_review_review_submitted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --unset-metadata gc.candidate_review_last_error >/dev/null; then
        echo "candidate-review-repair: $id review handoff succeeded but evidence update failed" >&2
        return 1
    fi
    echo "candidate-review-repair: resubmitted $id to $route"
}

route_repair() {
    local bead_json="$1" id status assignee route workflow owner correction target source residue landed state attempt max_attempts next output rc
    id="$(printf '%s' "$bead_json" | jq -r '.id // empty')"
    status="$(printf '%s' "$bead_json" | jq -r '.status // empty')"
    assignee="$(printf '%s' "$bead_json" | jq -r '.assignee // empty')"
    state="$(printf '%s' "$bead_json" | jq -r '.metadata["gc.candidate_review_state"] // empty')"

    case "$state" in
        published_pending_review|review_queued)
            route="$(printf '%s' "$bead_json" | jq -r '.metadata["gc.candidate_review_review_route"] // empty')"
            if [ -z "$route" ]; then
                echo "candidate-review-repair: $id has no explicit review route; preserving hold" >&2
                return 0
            fi
            if [ "$state" = "published_pending_review" ]; then
                if gc bd update "$id" --if-status "$status" --if-assignee "$assignee" \
                    --set-metadata gc.candidate_review_state=review_queued \
                    --set-metadata gc.candidate_review_review_queued_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null; then
                    :
                else
                    rc=$?
                    [ "$rc" -eq 13 ] && return 0
                    echo "candidate-review-repair: failed to claim review handoff for $id (exit $rc)" >&2
                    return 1
                fi
            fi
            route_review "$id" "$route"
            return $?
            ;;
        actionable|repair_failed)
            ;;
        *)
            return 0
            ;;
    esac

    [ "$status" = "open" ] || [ "$status" = "in_progress" ] || [ "$status" = "blocked" ] || return 0
    [ -n "$assignee" ] || return 0
    [ "$(printf '%s' "$bead_json" | jq -r '.metadata["gc.candidate_review_hold_class"] // empty')" = "mechanical" ] || return 0

    owner="$(printf '%s' "$bead_json" | jq -r '.metadata["gc.candidate_review_owner"] // empty')"
    correction="$(printf '%s' "$bead_json" | jq -r '.metadata["gc.candidate_review_correction"] // empty')"
    route="$(printf '%s' "$bead_json" | jq -r '.metadata["gc.candidate_review_repair_route"] // empty')"
    workflow="$(printf '%s' "$bead_json" | jq -r '.metadata["gc.candidate_review_repair_workflow"] // empty')"
    target="$(printf '%s' "$bead_json" | jq -r '.metadata["gc.candidate_review_target"] // empty')"
    source="$(printf '%s' "$bead_json" | jq -r '.metadata["gc.candidate_review_source"] // empty')"
    residue="$(printf '%s' "$bead_json" | jq -r '.metadata["gc.candidate_review_residue"] // empty')"
    landed="$(printf '%s' "$bead_json" | jq -r '.metadata["gc.candidate_review_landed"] // empty')"
    if [ -z "$owner" ] || [ -z "$correction" ] || [ -z "$route" ] || [ -z "$workflow" ] || [ -z "$target" ] || [ -z "$source" ] || [ -z "$residue" ] || [ -z "$landed" ]; then
        echo "candidate-review-repair: $id missing explicit correction/owner/source/target contract; preserving hold" >&2
        return 0
    fi

    attempt="$(printf '%s' "$bead_json" | jq -r '.metadata["gc.candidate_review_repair_attempt"] // "0"')"
    max_attempts="$(printf '%s' "$bead_json" | jq -r '.metadata["gc.candidate_review_max_attempts"] // "3"')"
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

    if gc bd update "$id" --if-status "$status" --if-assignee "$assignee" \
        --set-metadata gc.candidate_review_state=queued \
        --set-metadata gc.candidate_review_repair_attempt="$next" \
        --set-metadata gc.candidate_review_repair_queued_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --set-metadata gc.candidate_review_repair_owner="$owner" >/dev/null; then
        :
    else
        rc=$?
        # Exit 13 means another actor won the documented conditional write.
        [ "$rc" -eq 13 ] && return 0
        echo "candidate-review-repair: failed to claim $id (exit $rc)" >&2
        return 1
    fi

    if ! output="$(gc sling "$route" "$id" --on "$workflow" --no-convoy --reassign \
        --var "bead_id=$id" --var "repair_script=$WORKER" 2>&1)"; then
        gc bd update "$id" \
            --set-metadata gc.candidate_review_state=repair_failed \
            --set-metadata gc.candidate_review_last_error="repair dispatch failed: $output" \
            --append-notes "Candidate repair dispatch failed; retry is bounded by gc.candidate_review_max_attempts." >/dev/null
        echo "candidate-review-repair: $id dispatch failed: $output" >&2
        return 1
    fi
    echo "candidate-review-repair: queued $id attempt $next via $route ($workflow)"
}

while IFS= read -r bead_json; do
    [ -n "$bead_json" ] || continue
    route_repair "$bead_json"
done < <(printf '%s' "$BEADS_JSON" | jq -c '.[]')
