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

## The pipeline is not end-to-end yet

Everything below exists because the pipeline currently builds and gates and
then stops. Nothing is deployed, so the loop this project is named for does not
close.

**2. Deploy, smoke and rollback stages.**
Smoke verifies through the path a user takes, not a loopback port that returns
200 while the product is unreachable. Rollback is prepared before the change,
not improvised after it.

Rollback must branch on the smoke gate's *exit code* rather than on the CI
step's status, because `ci/run-gate.sh` collapses exit 1 and exit 2 into one
failure for the orchestrator — and "the smoke test found a broken deploy" and
"the smoke test could not run" call for different responses. Exit 2 also has no
honest `Outcome` to report to the consumer, which has to be settled rather than
guessed.

**3. The deploy job posts its own `DeploymentEvent`.**
The loop closes: the pipeline becomes both the subject and the source of its
own measurements. It must carry the full commit range rather than the head
commit — see [ADR 0002](https://github.com/jjackson0118/dora-loop/blob/main/docs/adr/0002-lead-time-is-per-change.md)
in the consumer repository, which is why the pipeline has to track the
previously deployed SHA.

**4. Review point — the deploy surface.**
Required before merge. New: a running service, deploy credentials, a database.
Every one of those is a way to be wrong at deploy time rather than in CI. The
question that matters most is whether the deploy job can lie — whether a failed
deploy can post `SUCCESS`, and whether anything at all would catch it.

## Then

**5. Dependency vulnerability gate.**
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
