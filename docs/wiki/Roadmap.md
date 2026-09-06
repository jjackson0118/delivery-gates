# Roadmap

Ordered, with the reason each item is where it is. Kept in the repository
rather than in a conversation, so it survives the session that produced it.

Review points are items in their own right, not something remembered at the
end. What each one covers is written down before the work starts, because a
review whose scope is decided afterwards tends to find what the author already
knew.

## Now

**1. More faults for paths nothing exercises.**
The corpus proves the gates catch the 17 defects it contains. The useful
question is the inverse: what could change in `lib/gate.sh` or a gate and still
pass all of them? Known gaps, none of them currently covered: a killed gate
(nothing reaches `ci/run-gate.sh`'s signal handling at all), a `fetch_verified`
checksum mismatch, `require_cmd` with a missing tool, a scanner timeout, the
`secrets` gate in `diff` mode — which is the mode the pipeline actually runs —
and nine of the `docs` gate's eleven rules.

An earlier version of this list carried a security review of the automation
surface and a fault-coverage gap analysis as outstanding items. Both were done;
[Review process](Review-Process.md) records them and their findings. They sat
here as pending for long enough that two documents in this directory disagreed
about the state of the repository, which a reviewer noticed and no gate could.

## Completed delivery loop

The consumer [dora-loop](https://github.com/jjackson0118/dora-loop) now builds,
gates, deploys, smoke-checks, and records its own deployment events. The
[deployment record](https://github.com/jjackson0118/dora-loop/wiki/Deployment)
links the authenticated CI run and independent target, database, and report
read-back. Replaying the recorded event returned `DUPLICATE` without adding a row.

Deployment scripts prepare recovery before activation and distinguish a smoke
finding from missing evidence. A demonstrated smoke defect triggers guarded
rollback; inconclusive smoke retains the release as `SUCCESS / UNVERIFIED` and
fails the job. Outcome and verification are independent fields, so failure to
measure is not invented as a failed rollout. Events carry the full commit range
since the captured baseline, including merged branch commits.

The deploy and reporting changes received independent reviews and isolated
failure tests before merge. That proves the checked scenarios; the successful
live run alone does not prove a live failure-and-recovery rehearsal. Consult the
dated deployment record for the exact scope of operational evidence.

## Then

**2. Dependency vulnerability gate.**
Gate on the dependency *delta*, not the inventory — a gate that fails on
day-one backlog is disabled within a week, and then it is decoration.
Suppressions carry an owner and an expiry. The gate asserts it examined
something and that its vulnerability database is fresh, because a stale
database returns zero findings and exits 0.

Explicitly below the finishing line. If it is not built properly it should not
be built at all: an unproven gate, in a repository whose entire argument is
that gates must be proven to fail, would be worse than the gap it fills.

## Not planned

These were scoped and then cut. They are recorded here rather than deleted,
because a roadmap that quietly loses items reads as a roadmap that was always
achievable.

- **A second orchestrator (Jenkins).** The plan was the same gates through a
  second adapter, with the controller declaratively configured so it is itself a
  versioned artifact. It is cut for effort against signal: a reviewer who is not
  convinced by gates that run identically under a harness and under GitHub
  Actions will not be convinced by a third caller. **The consequence is stated
  rather than absorbed** — portability remains a property of the design and is
  not a demonstrated fact, and the front page says so. The design evidence that
  does exist is that every gate is a plain script with a defined exit contract,
  called by two independent callers today, one of which is not a CI system.

- **Kubernetes and buildpacks.** Liveness and readiness probes, a rolling
  update, a rollback. The supervision concepts are already in the contract —
  exit 3 exists because of them — but demonstrating them needs a cluster, and
  the deploy target here is a single VM.

- **SAST.** Bundled with the dependency gate in an earlier version of this
  list. Much larger, and a far worse effort-to-signal ratio at this size.

- **AI failure triage.** Classifying a red build as product defect, flaky test,
  infrastructure or gate misconfiguration. The reasoning for it still stands —
  change failure rate is meaningless in any implementation that counts flaky
  infrastructure as change failures — and it is cut for scope rather than
  because it was a bad idea. If it were built, it would annotate and never
  change a verdict: an AI that can turn a build green is a gate that cannot
  fail.

- **A second human reviewer.** There isn't one. [Review process](Review-Process.md)
  describes what replaces it and is honest about what that does not cover.

- **Automating checklist rules 1 to 3.** They describe how a change is made
  rather than what it contains. Rule 4 could become a pre-push hook and has not
  been written.
