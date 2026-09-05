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

Exit 3 is now proven by `faults/contract-not-applicable`, which strips every
JVM build declaration from the fixture. It was the last code in the contract
with more prose than proof — reachable only from `shellcheck`, and never
exercised. The JVM gates used to return `gate_error` for a missing build file,
so pointing this suite at a non-JVM repository produced exit 2 where exit 3 was
the honest answer. They now distinguish the two by whether a build file
declares intent: no `build.gradle` and no `pom.xml` means this is not a JVM
project; a build file with no wrapper means one that is missing its wrapper.

**Every gate must declare what it examined.** A gate that examined nothing
exits `2`, never `0`. Most tools produce identical output for an empty scan and
a clean scan; treating those the same is how a check reports PASS for weeks
after its input quietly disappeared. Each gate writes a JSON report carrying
the finding count, the matched rule ids, and that denominator, and callers
assert against the report rather than grepping logs.

## Proving the gates

```
$ ./prove-gates-fail.sh ../dora-loop .
  fixture dora-loop        <sha>
  fixture delivery-gates   <sha>

=== direction 1: every gate must be QUIET on a clean tree ===
  -- fixture: dora-loop
  OK    docs               quiet on clean input          (floor 1)
  OK    gradle-wrapper     quiet on clean input          (floor 4)
  OK    jvm-test           quiet on clean input          (floor 25)
  OK    secrets            quiet on clean input          (floor 7)
  OK    shellcheck         quiet on clean input          (floor 1)
  -- fixture: delivery-gates
  OK    docs               quiet on clean input          (floor 20)
  OK    gradle-wrapper     not applicable, as declared (exit 3)
  OK    jvm-test           not applicable, as declared (exit 3)
  OK    secrets            quiet on clean input          (floor 10)
  OK    shellcheck         quiet on clean input          (floor 20)

=== direction 2: every declared fault must be CAUGHT ===
  OK    contract-bad-denominator caught by _synthetic (exit 2)
  OK    contract-broken-enumeration caught by shellcheck (exit 2)
  OK    contract-not-applicable caught by jvm-test (exit 3)
  OK    contract-open-expect-region caught by _synthetic (exit 2)
  OK    contract-unset-variable caught by _synthetic (exit 2)
  OK    contract-unwritable-reports caught by shellcheck (exit 2)
  OK    _control-noop      caught by secrets (exit 0)
  OK    docs-broken-citation caught by docs (exit 1, rule citation-missing-file)
  OK    gate-crashes-midway caught by gradle-wrapper (exit 2)
  OK    secrets-aws-key    caught by secrets (exit 1, rule generic-api-key)
  OK    secrets-private-key caught by secrets (exit 1, rule private-key)
  OK    secrets-suppressed-by-ignorefile caught by secrets (exit 1, rule private-key)
  OK    _selftest-phantom  harness correctly reported NOT CAUGHT for an uninjected fault
  OK    shellcheck-unquoted-var caught by shellcheck (exit 1, rule SC2164)
  OK    test-empty-suite   caught by jvm-test (exit 2)
  OK    test-failing-assertion caught by jvm-test (exit 1, rule test-failure)
  OK    wrapper-tampered-jar caught by gradle-wrapper (exit 1, rule wrapper-jar-checksum-mismatch)

=== result: 27 proven, 0 mismatched ===
```

**The `scanned` counts are deliberately not reproduced above, and the elision
is the point.** A real run prints one per row — `scanned <n> tests`,
`scanned <n> commits`. Those are denominators measured against a tree, so they
move with every commit, and `secrets` counts commits, which means *the commit
that updates this document changes the number this document reports*. Pasting
them is a treadmill that cannot be won, and it has been lost twice: once with a
transcript stale in six of ten rows, and once in the commit that fixed it, which
reported `shellcheck scanned 4` because a gitignored directory held three of my
own scripts, and cited a sha that was never merged.

What is printed here instead is what does not drift: the verdicts, the floors
(read from `fixtures/*.floors`), and `27 proven`, which is derived from
structure — gates × fixtures + faults — and is the one number `gates/docs.sh`
enforces. The `<sha>` lines are literal; every run prints which commit each
fixture was measured at, and refuses to hide uncommitted work.

For live numbers, run it, or read the [prove-gates workflow](.github/workflows/prove-gates.yml)
output. The harness clones each fixture rather than copying it, so a run on your
machine and a run in CI measure the same thing.

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

### Declared denominators

The harness takes more than one fixture, and needs to. `dora-loop` has no
`gates/` directory, so the docs gate's structural sections never executed
against it — 1 claim checked where this repository yields 27. A coverage
analysis deleted all four sections and the corpus stayed green. Running the
gates against this repository as well catches it: `docs scanned 3, floor is 20`.

`fixtures/<name>.floors` records the minimum each gate must report against a
fixture, and the harness fails when one drops below it. A gate with no entry is
an error rather than a skip — adding a gate and forgetting its floor would
otherwise opt it out of the only check that looks at scope. An entry also
declares the gate *applies*, so returning exit 3 there contradicts the
declaration and fails.

The denominator has to be a byproduct of the work rather than a parallel
calculation, or the floor measures the wrong thing. `secrets` used to count
commits with `git rev-list` while the scan range came from somewhere else:
narrowing the range to one commit left the count reporting ten. It now takes
the number from what gitleaks reports having scanned, and the floor catches the
narrowing.

**What this does not catch**, measured rather than assumed — five mutations
were run after the floors landed and one went red; the second fixture then
recovered another. A floor sees shrinkage it
can see. It does not see a gate that counts correctly and then hands the tool
fewer files, a reduction the fixture is too thin to expose, inflation, or a
semantic swap that produces the same number on this fixture. Those want faults
or a richer fixture, and both are on the [roadmap](docs/ROADMAP.md).

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
      gates-ref: main          # pin to a tag in production
      floors-path: .gates/floors
```

A gate improvement then reaches every consumer through a version bump instead
of N copy-pasted edits. Pinning `gates-ref` matters for the same reason: a
change to the gates should not be able to alter a consumer's verdict without a
deliberate bump.

### Declare what your gates cover

`.gates/floors` in your repository states, per gate, the minimum it must
examine — or `n/a` where a gate genuinely does not apply:

```
docs=3
gradle-wrapper=4
jvm-test=60
secrets=15
shellcheck=1
```

**This is not optional, and it is not tidiness.** Every gate already refuses to
pass on a *zero* denominator: `lib/gate.sh` turns `gate_scanned 0` into exit 2.
Nothing catches a gate that still runs and examines *less* than it used to, and
nothing catches a gate that decides your repository is out of scope — which
returns exit 3, which `ci/run-gate.sh` correctly maps to success, because an
orchestrator has only two states.

Measured on a repository containing one `.java` file and nothing else:

```
docs             gate=3  adapter=0
shellcheck       gate=3  adapter=0
gradle-wrapper   gate=3  adapter=0
jvm-test         gate=3  adapter=0
```

Four of five gates checked nothing and the pipeline was green. Deleting your
markdown, your shell scripts and your Gradle build is a way to pass this
pipeline. Until this file existed, floors were enforced only by
`prove-gates-fail.sh`, which runs inside *this* repository against *its own*
fixtures — so the guarantee this section used to describe was one consumers
never had. A reviewer found that; no gate here could have.

A missing floors file fails the build. `require-floors: false` accepts the gap,
and it should be a visible line in your workflow rather than the quiet default.
Set floors *below* current values: a floor equal to today's exact count goes red
on the next commit that legitimately deletes a file, and a check that cries wolf
gets deleted.

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

**`docs`** — checks documentation against the code it describes. Source
citations resolve to a real file and a real line; every gate is documented and
every documented gate exists; every fault named in prose is present; the
exit-code table matches what `lib/gate.sh` implements; the claimed proof count
equals gates x fixtures + faults; relative links resolve.

Only the mechanical half. Whether a paragraph is *true* still needs a reader —
but "does this line exist" and "does this number match the corpus" are
decidable, and those were most of what an adversarial review found. This
README once claimed 7 proven against an actual 13; nothing compared the number
to anything. It does now. Sections that describe this repository's own
structure are skipped on a consumer repo, which has markdown but no `gates/`.

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

## Reviewing changes

One maintainer, AI-assisted, no second human — so the review process is written
down rather than assumed: [`docs/REVIEW.md`](docs/REVIEW.md). It covers the
adversarial pass required before any change to the contract library, and five
checklist rules, each earned by a specific failure in this repository's history.

It also states which parts are enforced by a gate and which are only habit,
because a checklist presented as a control is the same category of error as a
green result standing in for a measurement.

What is left to build, in order and with the reasoning, is in
[`docs/ROADMAP.md`](docs/ROADMAP.md). Review points are items in that list
rather than something remembered at the end.

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
