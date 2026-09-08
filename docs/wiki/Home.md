# delivery-gates

CI/CD gates as portable scripts, wrapped for GitHub Actions — and a harness
that proves each one fires.

Most CI checks are trusted because they are green. Nobody has watched them go
red on purpose, so nobody knows whether they can. This repository is an
argument that the second thing is what makes the first thing mean anything, and
an attempt to hold itself to it.

Three ideas carry most of it:

**A gate that examined nothing must not pass.** Almost every tool prints the
same output for a clean scan and an empty one, which is how a check reports
PASS for weeks after its input quietly moved. Every gate here declares what it
examined, and a zero denominator is an error rather than a success.

**A gate nobody has seen fail is not known to work.** A fault corpus injects a
real defect and asserts the exact exit code and the exact rule id that must
fire. Two of the entries exist to test the harness rather than the gates: one
injects nothing and must come back clean, and one declares a fault it never
injects and the harness is *required* to report it as not caught.

**The gate is a script, not a workflow.** If a check can only be expressed in
one vendor's YAML, it is a feature of that vendor. Everything here is a plain
script with a defined exit contract, called by the CI workflow and by the
harness — so the proof exercises the real gate rather than a copy of it.

## Where to start

- **[The gate contract](The-Gate-Contract.md)** — the four exit codes, and why
  `1` and `2` must not be collapsed into "non-zero".
- **[Proving the gates fail](Proving-Gates-Fail.md)** — the harness, a full run,
  declared denominators, and what the floors do *not* catch. The most load-bearing
  page here.
- **[Using it](Using-It.md)** — calling the reusable workflow from your own
  repository, and declaring what your gates cover.
- **[The gates](The-Gates.md)** — what each one checks and the specific failure
  that motivated it.
- **[Review process](Review-Process.md)** — one maintainer, no second human,
  and what stands in for one. Honest about what it does not cover.
- **[How it was built](How-It-Was-Built.md)** — one weekend, one person, two AI
  agents; who did what, what the review loop caught, and why every comment
  was left in.
- **[Roadmap](Roadmap.md)** — what is left, in order, and what was cut.

## Honest limits

Portability is a property of the design and not a demonstrated fact. A second
orchestrator was scoped and cut, so the evidence is that every gate is a plain
script with a defined contract called by two independent callers, one of which
is not a CI system — not that it has been run under Jenkins.

The `secrets` scanner is checksum-pinned, but gitleaks publishes no checksums
for its release archives, so the pin was captured by hand from one download. It
detects a later substitution; it does not verify the original. That is trust on
first use, and calling it verification would overstate it.

Several things on the roadmap are not built. Where that is true, the page says
so rather than describing the intention in the present tense.
