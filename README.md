# delivery-gates

CI/CD gates as scripts, wrapped for GitHub Actions and Jenkins — and a harness
that proves each one fires.

## The idea

A platform team's product is not a pipeline. It is the paved road other teams
drive on. So the gates here are plain scripts with a defined contract, and the
CI platform is a thin wrapper over them:

```
gates/secrets.sh  <-- the gate
      ^      ^
      |      +---- .github/workflows/  (GitHub Actions calls it)
      |      +---- jenkins/Jenkinsfile (Jenkins calls it)
      +----------- prove-gates-fail.sh (the harness calls the same script)
```

If a gate is only expressible in workflow YAML, it isn't a gate — it's a
feature of one CI vendor. Scripts port; YAML doesn't. It also means the proof
exercises the real gate rather than a copy of it, which is the difference
between evidence and theatre.

## The contract

| exit | meaning |
|---|---|
| `0` | the gate ran, examined something, and found nothing |
| `1` | the gate ran and found the thing it looks for |
| `2` | the gate could not run, or ran and examined nothing |

The `1`/`2` split carries most of the weight. A caller that treats "non-zero"
as proof a gate fired will accept a scanner that crashed on startup — which
proves nothing and is indistinguishable from coverage.

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
  OK    secrets            quiet on clean input (exit 0)

=== direction 2: every declared fault must be CAUGHT ===
  OK    _control-noop      caught by secrets (exit 0)
  OK    secrets-aws-key    caught by secrets (exit 1, rule generic-api-key)
  OK    secrets-private-key caught by secrets (exit 1, rule private-key)
  OK    _selftest-phantom  harness correctly reported NOT CAUGHT for an uninjected fault
  OK    wrapper-tampered-jar caught by gradle-wrapper (exit 1, rule wrapper-jar-checksum-mismatch)

=== result: 7 proven, 0 mismatched ===
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

## Gates

**`gradle-wrapper`** — `gradle-wrapper.jar` is ~43 KB of opaque bytecode,
committed to source control, executed on every developer machine and every CI
runner before a line of project code compiles. A pull request that swaps it
renders as "Binary file not shown", so no review has ever read it. Checks the
jar against Gradle's published checksums, *and* `gradlew`/`gradlew.bat`, which
Gradle publishes no checksums for and which run first, *and* that
`distributionSha256Sum` is set — because validating the launcher says nothing
about the distribution the launcher then downloads.

**`secrets`** — gitleaks, checksum-pinned, `--redact` always. Diff mode blocks;
history mode reports on a schedule and does not block, because a history scan
never goes green again once it finds something, and gating merges on it turns
into an allowlist nobody reads. Its output is a rotation list, not a merge
decision.

The scanner is fetched over the network and then decides whether the build
ships, so it is checksum-pinned. Noted honestly in the source: gitleaks
publishes no checksums file for its release archives, so that pin was captured
by hand from one download. It detects a later substitution; it does not verify
the original. That is trust on first use, and calling it verification would
overstate it.

## Roadmap

- `build`, `test`, and dependency-vulnerability gates
- Reusable `workflow_call` workflow, versioned and released, consumed by
  [`dora-loop`](https://github.com/jjackson0118/dora-loop)
- Jenkins wrapper via JCasC + Compose — the same gates, a second orchestrator
- AI failure triage: classify a red build as product defect / flaky test /
  infrastructure / gate misconfiguration, evaluated against a fixture corpus.
  It annotates and never changes the verdict: an AI that can turn a build green
  is a gate that cannot fail.

## License

Apache-2.0.
