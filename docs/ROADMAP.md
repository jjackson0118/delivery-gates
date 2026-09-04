# Roadmap

Ordered, with the reason each item is where it is. Kept in the repository
rather than in a conversation, so it survives the session that produced it.

Review points are items in their own right, not something remembered at the
end. What each one covers is written down before the work starts, because a
review whose scope is decided afterwards tends to find what the author already
knew.

## Now

**1. Security review of the automation surface.**
A fine-grained PAT now lives on the build host and two scripts read it to open
and merge pull requests. That is a new credential and a new privilege path, and
it was added without review. Covers: token scope against actual need, the
scripts that read it, `GITHUB_TOKEN` permissions in every workflow, and the two
deploy keys. Owed since the automation landed.

**2. Fault-coverage gap analysis.**
The corpus proves the gates catch 21 defects. The useful question is the
inverse: what could change in `lib/gate.sh` or a gate and still pass all 21?
An adversarial review of the contract library already found six such holes, so
the answer is not zero. Output becomes new faults.

## The pipeline is not end-to-end yet

Everything below exists because the pipeline currently builds and gates and
then stops. Nothing is deployed, so the loop this project is named for does not
close.

**3. The `api` module.**
Spring Boot, ingest and metrics endpoints, actuator health, Postgres behind
Flyway. Two things depend on it: there is nothing to deploy without it, and
`core` has no runtime dependencies, so a vulnerability scanner would examine
nothing and exit 0 — the failure this repository exists to argue about, in the
scanner meant to prevent it.

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
