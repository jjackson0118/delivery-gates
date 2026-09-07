# Review process

One maintainer, AI-assisted, no second human — so the review process is written
down rather than assumed. This page covers the adversarial pass required before
any change to the contract library, and five checklist rules, each earned by a
specific failure in this repository's history.

It also states which parts are enforced by a gate and which are only habit,
because a checklist presented as a control is the same category of error as a
green result standing in for a measurement.

What is left to build, in order and with the reasoning, is on the
[Roadmap](Roadmap.md). Review points are items in that list rather than
something remembered at the end.

This repository is maintained by one person working with AI assistance — the
account of which agents did what is on [How it was built](How-It-Was-Built.md). There
is no second human, so "get a review" cannot mean what it means on a team. What
follows is what replaces it, and an honest account of why each part exists.

## Three layers

**1. Gates.** Mechanical, run on every push, block the merge. They catch what
they were built to catch and nothing else.

**2. An adversarial agent pass.** Ideally on every change; in practice often
enough to keep the contract library honest, which so far has meant roughly one
review per three or four merges.

This is written as an aspiration rather than a gate because that is what it is.
It said "required" for a while and then slipped three merges in a row, and a
document asserting a control that does not fire is the same failure this
repository is about — so it says what happens instead of what ought to.

When it slips, the cost is measurable rather than theoretical: those three
merges contained a hole that let the harness fabricate its own proof, a way for
a repository under test to switch off the secret scanner, and a floors file
encoding that silently disabled every floor. All three were found by the next
review, none by the gates.

**3. The checklist.** Five rules, each earned by a specific failure.

## Why layer 2 exists

One adversarial review of the contract library found **six** ways to reach a
wrong verdict. All six were in code that had already passed four gates and
eighteen proofs. The worst: the secret scanner could find secrets, discard
them, and report PASS — the ERR trap does not propagate out of process
substitution, so the abort happened in a subshell whose exit status the parent
discarded, and `gate_finish` then overwrote the error report with a pass.

Every one of the six was invisible to `prove-gates-fail.sh`, which injects
source defects into fixtures and had never exercised a broken enumeration, an
unwritable report directory, or a malformed denominator. There
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

## What the first two reviews found

Recorded because the numbers are the argument for doing this at all.

**Contract review** (six blockers, all in code that had passed four gates and
eighteen proofs). The worst: the secret scanner could find secrets, discard
them, and report PASS.

**Security review of the automation surface** (three critical). The build host
has passwordless sudo, and the harness executes repository content — `fault.env`
is sourced, `inject.sh` is run, `./gradlew` evaluates build logic at
configuration time — so running it against a tree you did not write is a host
takeover. Separately, the PAT held `Workflows: write`, which no script used and
which let it rewrite the required status check and then satisfy it.

**Fault-coverage analysis** (30 mutations tried, **20 survived all 21 proofs**).
`gate_scanned "$executed"` → `"$total"` is one token and turns a fully-disabled
suite into `PASS over 30 tests`. The vacuity rule itself — the most-argued line
in `lib/gate.sh` — had no fault reaching it. And a `fault.env` could redefine
the harness's own `run_gate_in`, producing *22 proven, 0 mismatched* with every
direction-2 row fabricated and a real defect passed over.

The lesson is not that the corpus was bad. **A fault corpus proves the gates
catch the defects someone thought of.** Finding the defects nobody thought of is
a different activity, which is why it is scheduled here rather than hoped for.

## The checklist

Five rules. Each exists because of a specific failure in this repository's
history, named so the rule is not mistaken for ceremony.

(This said "four" while listing five, in a document about verifying claims. A
reviewer counted; nothing else did.)

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

### 4. Calibrate a threshold where it will run

The declared floors were set from this working copy. One of them read 15 where
CI saw 13, because the local repository still held remote-tracking refs for six
branches deleted on GitHub — the number encoded local ref debris rather than the
repository.

**Rule:** any threshold measured from a developer's checkout is measured in the
wrong place. Clone to a temp directory and measure there, and leave margin: a
threshold sitting exactly on an observed value is a flaky check, and a flaky
check contaminates every result beside it.

### 5. Verify the gate passes before pushing

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
gates x fixtures + faults, relative links resolve.

None of the five is enforced by anything. They are habits, written down
because each was learned by shipping the failure. Automating rules 4 and 5 is
possible — a pre-push hook — and is not built. Rules 1 to 3 describe how a
change is made rather than what it contains, and are probably not mechanisable.
Saying so is better than implying the checklist is a control.
