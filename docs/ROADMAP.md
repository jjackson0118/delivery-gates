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

Items 1 and 2 of this list used to be a security review of the automation
surface and a fault-coverage gap analysis. Both were done; `docs/REVIEW.md`
records them and their findings. They sat here as outstanding work for long
enough that two documents in this directory disagreed about the state of the
repository, which a reviewer noticed and no gate could.

## The pipeline is not end-to-end yet

Everything below exists because the pipeline currently builds and gates and
then stops. Nothing is deployed, so the loop this project is named for does not
close.

**4. Deploy, smoke and rollback stages.**
Smoke verifies through the path a user takes, not a loopback port that returns
200 while the product is unreachable. Rollback is prepared before the change,
not improvised after it.

**5. The deploy job posts its own `DeploymentEvent`.**
The loop closes: the pipeline becomes both the subject and the source of its
own measurements. It must carry the full commit range rather than the head
commit — see [ADR 0002](https://github.com/jjackson0118/dora-loop/blob/main/docs/adr/0002-lead-time-is-per-change.md)
in the consumer repository, which is why the pipeline has to track the
previously deployed SHA.

**6. Review point — the deploy surface.**
Required before merge. New: a running service, deploy credentials, a database,
and a smoke-test account. Every one of those is a way to be wrong in production
rather than in CI.

## Then

**7. Dependency vulnerability gate, and SAST.**
Gate on the dependency *delta*, not the inventory — a gate that fails on
day-one backlog is disabled within a week, and then it is decoration.
Suppressions carry an owner and an expiry. The gate asserts it examined
something and that its vulnerability database is fresh, because a stale
database returns zero findings and exits 0.

**8. AI failure triage.**
Classifies a red build as product defect, flaky test, infrastructure, or gate
misconfiguration. This is load-bearing rather than decorative: change failure
rate is meaningless in every implementation that counts flaky infrastructure as
change failures. It annotates and never changes a verdict — an AI that can turn
a build green is a gate that cannot fail. Evaluated against a fixture corpus of
known-flaky and known-real failures, because an unevaluated model in a pipeline
is exactly the thing this repository objects to.

**9. Kubernetes and buildpacks.**
Liveness and readiness probes, a rolling update, a rollback. The supervision
concepts are already in the contract — exit 3 exists because of them.

**10. Jenkins.**
The same gates through a second adapter, with the controller declaratively
configured so it is itself a versioned artifact. Until this exists, the
portability claim is a property of the design and not a demonstrated fact, and
the README says so.

## Not planned

- **A second human reviewer.** There isn't one. [`REVIEW.md`](REVIEW.md)
  describes what replaces it and is honest about what that does not cover.
- **Automating checklist rules 1 to 3.** They describe how a change is made
  rather than what it contains. Rule 4 could become a pre-push hook and has not
  been written.
