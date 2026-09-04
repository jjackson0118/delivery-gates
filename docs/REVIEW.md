# Review process

This repository is maintained by one person working with AI assistance. There
is no second human, so "get a review" cannot mean what it means on a team. What
follows is what replaces it, and an honest account of why each part exists.

## Three layers

**1. Gates.** Mechanical, run on every push, block the merge. They catch what
they were built to catch and nothing else.

**2. An adversarial agent pass** before merging any change to `lib/gate.sh`,
`ci/run-gate.sh`, or `prove-gates-fail.sh`. Scoped, written down below, and
required — not run when it occurs to someone.

**3. The checklist.** Four rules, each earned by a specific failure.

## Why layer 2 exists

One adversarial review of the contract library found **six** ways to reach a
wrong verdict. All six were in code that had already passed four gates and
eighteen proofs. The worst: the secret scanner could find secrets, discard
them, and report PASS — the ERR trap does not propagate out of process
substitution, so the abort happened in a subshell whose exit status the parent
discarded, and `gate_finish` then overwrote the error report with a pass.

Every one of the six was invisible to `prove-gates-fail.sh`, which injects
source defects into fixtures and had never exercised a broken enumeration, an
unwritable report directory, a killed gate, or a malformed denominator. There
is now a fault for each, from `faults/contract-broken-enumeration` through
`faults/contract-open-expect-region`.

The lesson is not that the harness was bad. It is that **a fault corpus proves
the gates catch the defects someone thought of.** Finding the defects nobody
thought of is a different activity, and it has to be scheduled rather than
hoped for.

## Scope of the adversarial pass

The reviewer is asked to verify by execution, not by reading, and to report
what is solid as well as what is broken. Minimum coverage:

- Can a gate exit with a code outside `0|1|2|3`? Signals, `set -u` violations,
  a full disk, a read-only report directory, a failure inside the error handler.
- Can the vacuity rule be bypassed? Non-numeric, empty, or negative denominators.
- Can `_gate_write_report` emit invalid JSON? Control characters, quotes,
  backslashes, very long strings — rule ids come from the repository under test.
- Does the ERR trap fire everywhere it is assumed to? Functions, subshells,
  command substitution, pipelines, process substitution.
- Re-entrancy: double `gate_finish`, `gate_error` from inside the trap,
  sourcing the library twice.
- Anything that can hang without a timeout.

## The checklist

Four rules. Each exists because of a specific failure in this repository's
history, named so the rule is not mistaken for ceremony.

### 1. Verify the edit applied

A commit titled *"stop README overclaiming"* changed two files, neither of them
the README. A `str.replace()` used `--` where the file had em dashes: it matched
nothing, returned the string unchanged, wrote it back byte-identical, and git
recorded no diff. No error anywhere, and the fix was reported as done.

**Rule:** every scripted edit asserts its pattern matched before writing, and
the change is grepped for afterwards.

### 2. Verify the message reads back

A commit message written with `-m` inside double quotes contained backticks.
The shell executed them as command substitution and the path being described
was replaced by the empty output of trying to run it.

**Rule:** commit messages go through `-F` with a quoted heredoc, and are read
back with `git log -1`.

### 3. Verify local and CI run the same test

An adapter self-test passed locally and failed on the runner. The local probe
had been updated during the fix; the one in `ci.yml` had not. Local green said
nothing about CI, because they were different tests.

**Rule:** when a test exists in both places, change both or neither, and run
the CI version verbatim before pushing.

### 4. Verify the gate passes before pushing

A branch was committed and a pull request opened before running the gates
locally. The required check found seven findings that a fifteen-second local
run would have caught.

**Rule:** `./ci/run-gate.sh ./gates/<gate>.sh .` for every affected gate, and
`./prove-gates-fail.sh <fixture>` for any change under `gates/`, `lib/`, or
`faults/`, before the branch is pushed.

## What is enforced versus what is habit

`gates/docs.sh` enforces the mechanical half of documentation accuracy:
citations resolve, gates are documented, faults named in prose exist, the
exit-code table matches the implementation, the claimed proof count equals
gates plus faults, relative links resolve.

Rules 1 through 4 are **not** enforced by anything. They are habits, written
down because each was learned by shipping the failure. Automating rule 4 is
possible — a pre-push hook — and is not built. Rules 1 to 3 describe how a
change is made rather than what it contains, and are probably not mechanisable.
Saying so is better than implying the checklist is a control.
