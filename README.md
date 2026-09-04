# delivery-gates

CI/CD gates as portable scripts, wrapped for GitHub Actions — and a harness
that proves each one fires.

## The idea

A platform team's product is not a pipeline. It is the paved road other teams
drive on. So the gates here are plain scripts with a defined contract, and the
CI platform is a thin wrapper over them:

```
gates/secrets.sh  <-- the gate
      ^      ^
      |      +---- .github/workflows/  (GitHub Actions calls it)
      +----------- prove-gates-fail.sh (the harness calls the same script)
```

If a gate is only expressible in workflow YAML, it isn't a gate — it's a
feature of one CI vendor. Scripts port; YAML doesn't. It also means the proof
exercises the real gate rather than a copy of it, which is the difference
between evidence and theatre.

A Jenkins wrapper is on the roadmap and **not built yet**. Portability is a
property of the design; a second orchestrator is not something this repository
can demonstrate today.

## The contract

| exit | meaning |
|---|---|
| `0` | the gate ran, examined something, and found nothing |
| `1` | the gate ran and found the thing it looks for |
| `2` | the gate could not run, or ran and examined nothing |
| `3` | the gate does not apply to this repository |

The `1`/`2` split carries most of the weight. A caller that treats "non-zero"
as proof a gate fired will accept a scanner that crashed on startup — which
proves nothing and is indistinguishable from coverage.

`3` exists because `2` was doing two jobs. A shell linter pointed at a Java
repository has not failed and has not found anything — it does not apply, and
that is a third answer. Collapsing it into "error" makes a correct outcome look
like a broken gate; collapsing it into "pass" is worse, because it claims
coverage that was never possible. The distinction is borrowed from a
service-admission contract on another system, where the same conflation caused
a real incident: a supervisor killed and restarted a service nine times
overnight on nodes where its prerequisites could never be satisfied. The service
was not unhealthy. It was not applicable, and nothing could express that.

Honest caveat: exit 3 is still the one code with **no proving fault**. It is reachable
only from `shellcheck`, and only against a repository with no shell files at all
— the JVM fixture has `gradlew`, which the gate finds by shebang. The other gates
treat a missing build file as `gate_error`, so pointing this suite at a non-JVM
repository still produces exit 2 where exit 3 would be more honest.

**Every gate must declare what it examined.** A gate that examined nothing
exits `2`, never `0`. Most tools produce identical output for an empty scan and
a clean scan; treating those the same is how a check reports PASS for weeks
after its input quietly disappeared. Each gate writes a JSON report carrying
the finding count, the matched rule ids, and that denominator, and callers
assert against the report rather than grepping logs.

## Proving the gates

```
$ ./prove-gates-fail.sh ../dora-loop
=== direction 1: every gate must be QUIET on a clean tree ===
  OK    gradle-wrapper     quiet on clean input (exit 0)
  OK    jvm-test           quiet on clean input (exit 0)
  OK    secrets            quiet on clean input (exit 0)
  OK    shellcheck         quiet on clean input (exit 0)

=== direction 2: every declared fault must be CAUGHT ===
  OK    contract-bad-denominator caught by _synthetic (exit 2)
  OK    contract-broken-enumeration caught by shellcheck (exit 2)
  OK    contract-open-expect-region caught by _synthetic (exit 2)
  OK    contract-unset-variable caught by _synthetic (exit 2)
  OK    contract-unwritable-reports caught by shellcheck (exit 2)
  OK    _control-noop      caught by secrets (exit 0)
  OK    gate-crashes-midway caught by gradle-wrapper (exit 2)
  OK    secrets-aws-key    caught by secrets (exit 1, rule generic-api-key)
  OK    secrets-private-key caught by secrets (exit 1, rule private-key)
  OK    _selftest-phantom  harness correctly reported NOT CAUGHT for an uninjected fault
  OK    shellcheck-unquoted-var caught by shellcheck (exit 1, rule SC2164)
  OK    test-empty-suite   caught by jvm-test (exit 2)
  OK    test-failing-assertion caught by jvm-test (exit 1, rule test-failure)
  OK    wrapper-tampered-jar caught by gradle-wrapper (exit 1, rule wrapper-jar-checksum-mismatch)

=== result: 18 proven, 0 mismatched ===
```

Both directions are required. A gate never observed refusing anything is not
known to work; a gate never observed accepting anything is not known to
discriminate. Only the pair shows it is measuring something.

Faults assert an **exact** exit code and, where applicable, the **exact rule
id** that must appear in the report. That second assertion is not pedantry.
The `secrets-aws-key` fault originally expected a rule named
`aws-access-token`; the gate returned exit 1, so an exit-code-only check would
have passed — but the rule that actually fired was `generic-api-key`, because
gitleaks 8.30.1 ships no AWS-specific rule that matches a bare `AKIA`
identifier. The expected rule had been written from memory rather than from
observation. Right answer, wrong reason, and only the rule assertion caught it.

### Who tests the harness

- `faults/_control-noop` injects nothing and must come back clean. Anything red
  there means a flaky gate is contaminating every other row.
- `faults/_selftest-phantom` declares a fault it never injects. The harness is
  *required* to report a mismatch for it. If this harness ever reports "caught"
  for a fault that was never applied, every other row is worthless.

## Using it

A consumer repository calls the reusable workflow rather than copying gate
steps:

```yaml
jobs:
  pipeline:
    uses: jjackson0118/delivery-gates/.github/workflows/reusable-jvm-pipeline.yml@main
    with:
      java-version: "21"
      gates-ref: main   # pin to a tag in production
```

A gate improvement then reaches every consumer through a version bump instead
of N copy-pasted edits. Pinning `gates-ref` matters for the same reason: a
change to the gates should not be able to alter a consumer's verdict without a
deliberate bump.

## Gates

**`gradle-wrapper`** — `gradle-wrapper.jar` is ~43 KB of opaque bytecode,
committed to source control, executed on every developer machine and every CI
runner before a line of project code compiles. A pull request that swaps it
renders as "Binary file not shown", so no review has ever read it. Checks the
jar against Gradle's published checksums, *and* `gradlew`/`gradlew.bat`, which
Gradle publishes no checksums for and which run first, *and* that
`distributionSha256Sum` is set — because validating the launcher says nothing
about the distribution the launcher then downloads.

**`jvm-test`** — runs the suite and asserts it executed something. "BUILD
SUCCESSFUL" is printed when the test task was `UP-TO-DATE` and never ran, when
the source set is empty and the task reports `NO-SOURCE`, and when the suite
genuinely passed — three very different situations, one output. So the gate
reads the JUnit XML and counts rather than trusting the build's exit code, and
zero executed tests is an **error**, not a pass. It also fails if the build
result and the test results disagree, because then neither should be believed.
The `test-empty-suite` fault deletes every test: Gradle reports success and the
gate returns exit 2.

**`shellcheck`** — static analysis of shell scripts, discovered by extension
*and* by shebang, because an extension-only glob misses every extensionless
executable — `gradlew` being the obvious one, and it runs on every machine
before anything else does. Returns exit 3 rather than 0 on a repository with no
shell files.

This gate exists because the repository was violating its own argument. The
check was an inline `apt-get install && shellcheck` step in `ci.yml`, which made
it the one check here that could not be run locally, could not be run by
Jenkins, and could not be exercised by `prove-gates-fail`. The check watching
every other script was the only one with no proof that it fires.

**`secrets`** — gitleaks, checksum-pinned, `--redact` always. Diff mode blocks and
is what the pipeline runs. History mode is implemented in the gate but is **not
yet wired to a scheduled workflow** — its only caller today is the fault harness.
The intended split, once wired: history reports and does not block, because a
history scan never goes green again once it finds something, and gating merges
on it turns into an allowlist nobody reads. Its output is a rotation list, not a
merge decision.

The scanner is fetched over the network and then decides whether the build
ships, so it is checksum-pinned. Noted honestly in the source: gitleaks
publishes no checksums file for its release archives, so that pin was captured
by hand from one download. It detects a later substitution; it does not verify
the original. That is trust on first use, and calling it verification would
overstate it.

## Roadmap

- `build` and dependency-vulnerability gates
- Tag and release the reusable workflow, so `gates-ref` can pin a version rather
  than a moving branch (the workflow exists and is consumed by
  [`dora-loop`](https://github.com/jjackson0118/dora-loop))
- Jenkins wrapper via JCasC + Compose — the same gates, a second orchestrator
- AI failure triage: classify a red build as product defect / flaky test /
  infrastructure / gate misconfiguration, evaluated against a fixture corpus.
  It annotates and never changes the verdict: an AI that can turn a build green
  is a gate that cannot fail.

## License

Apache-2.0.
