# Proving the gates fail

The command below executes repository code, including fixture builds and fault
injectors. Use a disposable environment without host credentials or unrelated
services, not a privileged account on a shared host. Scratch clones isolate
files; they do not sandbox execution. See [Using it](Using-It.md) for the
separately reproduced local static checks and prerequisites.

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
  OK    smoke              not applicable, as declared (exit 3)
  -- fixture: delivery-gates
  OK    docs               quiet on clean input          (floor 20)
  OK    gradle-wrapper     not applicable, as declared (exit 3)
  OK    jvm-test           not applicable, as declared (exit 3)
  OK    secrets            quiet on clean input          (floor 10)
  OK    shellcheck         quiet on clean input          (floor 20)
  OK    smoke              not applicable, as declared (exit 3)

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
  OK    secrets-aws-key    caught by secrets (exit 1, rule aws-access-token)
  OK    secrets-private-key caught by secrets (exit 1, rule private-key)
  OK    secrets-suppressed-by-ignorefile caught by secrets (exit 1, rule private-key)
  OK    _selftest-phantom  harness correctly reported NOT CAUGHT for an uninjected fault
  OK    shellcheck-unquoted-var caught by shellcheck (exit 1, rule SC2164)
  OK    test-empty-suite   caught by jvm-test (exit 2)
  OK    test-failing-assertion caught by jvm-test (exit 1, rule test-failure)
  OK    wrapper-tampered-jar caught by gradle-wrapper (exit 1, rule wrapper-jar-checksum-mismatch)

=== result: 29 proven, 0 mismatched ===
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
(read from `fixtures/*.floors`), and `29 proven`, which is derived from
structure — gates × fixtures + faults — and is the one number `gates/docs.sh`
enforces. The `<sha>` lines are literal; every run prints which commit each
fixture was measured at, and refuses to hide uncommitted work.

For live numbers, run it, or read the [prove-gates workflow](https://github.com/jjackson0118/delivery-gates/blob/main/.github/workflows/prove-gates.yml)
output. The harness clones each fixture rather than copying it, so a run on your
machine and a run in CI measure the same thing.

Both directions are required. A gate never observed refusing anything is not
known to work; a gate never observed accepting anything is not known to
discriminate. Only the pair shows it is measuring something.

Faults assert an **exact** exit code and, where applicable, the **exact rule
id** that must appear in the report. That second assertion is not pedantry.
The `secrets-aws-key` fault has been wrong twice, in opposite directions, and
both were caught only by asserting the rule.

First it expected `aws-access-token` written from memory; the gate returned
exit 1, so an exit-code-only check passed, while the rule that fired was
`generic-api-key`. The correction then overshot into a second false claim —
that gitleaks 8.30.1 ships no AWS rule matching a bare `AKIA` identifier. It
does. It applies an entropy test to the identifier, so a *randomly generated*
one triggers it only sometimes: over 30 runs of the injector,
`aws-access-token` fired 3 times and `generic-api-key` all 30. Those are not
alternatives — the generic rule fires on every run, including the three.

So the fault was nondeterministic, and a fresh clone once reported
`26 proven, 1 mismatched` against the working tree's 27 and 0. The identifier
is fixed now and the rule is `aws-access-token` every time. A fault whose job
is to assert the rule cannot have a rule that depends on the draw.

### Declared denominators

The harness takes more than one fixture, and needs to. `dora-loop` has no
`gates/` directory, so the docs gate's structural sections never executed
against it — 5 claims checked there where this repository yields 28. A coverage
analysis deleted all four sections and the corpus stayed green. Running the
gates against this repository as well catches it: with those sections removed
this repository reports `docs scanned 4` against a floor of 20.

(Those three numbers were 1, 27 and 3 until a reviewer measured them. They are
denominators, and a denominator written from memory is the thing this file is
about. They were also copied into four other places, which is why the figure
now appears once.)

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
or a richer fixture, and both are on the [roadmap](Roadmap.md).

### Who tests the harness

- `faults/_control-noop` injects nothing and must come back clean. Anything red
  there means a flaky gate is contaminating every other row.
- `faults/_selftest-phantom` declares a fault it never injects. The harness is
  *required* to report a mismatch for it. If this harness ever reports "caught"
  for a fault that was never applied, every other row is worthless.
