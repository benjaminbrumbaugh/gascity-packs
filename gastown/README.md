# Gastown Pack

Gastown is the domain-specific coding workflow pack. It provides the city
coordinator roles, rig worker roles, patrol formulas, and the pack-local dog
pool used for stuck-agent shutdown warrants.

## Import

```toml
[imports.gastown]
source = "../packs/gastown"
```

Use the pack as the workspace pack for city-scoped agents and as a rig pack for
rig-scoped agents.

## Composition

Gas City composes the builtin core pack (mechanical housekeeping orders)
through the explicit `includes` entries that `gc init` writes into
city.toml; this pack composes alongside it via `[imports.gastown]`. The
retired maintenance pack no longer exists: gastown's `mol-shutdown-dance`
and dog prompt fragments (`propulsion-dog`, `architecture`,
`following-mol`) are the only copies in play, and cross-pack agent name
collisions are hard errors rather than fallback resolutions.

Verify the composed recipe after changing imports:

```bash
gc formula show mol-shutdown-dance
```

The recipe must read warrant metadata from the claimed bead via
`$GC_BEAD_ID` and must not declare a required `warrant_id` var.

## Dog Pool

Gastown owns `mol-shutdown-dance` and the dog agent that runs stuck-agent
warrants, including the dog's `wake_mode` and `work_dir` settings. In import
composition gastown's dog expands as the distinct `gastown.dog` agent; the
dolt pack ships its own separate dog for Dolt maintenance formulas, and the
two coexist under their binding-qualified names.

Gastown deliberately does not ship retired dog formulas for JSONL export or
stale-session reaping. The Gas City builtin core pack provides JSONL export,
stale-session and stale-data cleanup, and Dolt housekeeping as deterministic
exec orders.

## Candidate-review repair

The `candidate-review-repair` order runs once per minute in each rig and only
selects review holds that explicitly declare a complete
`gc.candidate_review_*` contract with `hold_class=mechanical`. It atomically
claims one repair attempt with a unique CAS token and routes the source bead
through the fixed `mol-candidate-review-repair` Graph v2 formula. The formula
binds the worker to its trusted current worktree and declared source branch;
the worker stages only declared paths.

The loop is intentionally fail-closed. Human or external decisions, missing
ownership or routes, malformed or symlink paths, changed contracts, CAS
conflicts, dirty worktrees, writer-lock conflicts, non-fast-forward races, and
exhausted attempts remain held with durable evidence. The worker always runs
its mandatory `git diff --check` and then any non-empty operator-owned gates,
publishes only through a normal fast-forward, and resubmits the source bead
through its explicit review route. Operators must never classify an uncertain
correction as mechanical merely to clear a queue.
