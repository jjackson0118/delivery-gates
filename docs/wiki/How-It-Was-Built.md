# How it was built

This repository and [dora-loop](https://github.com/jjackson0118/dora-loop) were
built over one weekend by one person directing AI coding agents: the first
commit landed on Friday 4 September 2026 at 16:11, the last build commit on
Sunday 6 September at 15:27. Monday 7 September was a review pass, branch
cleanup, and this documentation — so the contribution graph shows four days,
and "two days" below means the build.

That it was built this way is not a disclosure buried at the bottom; it is half
of what the two repositories are for. The other half is the delivery loop they
implement. This page is the account of the first half.

## Who did what

**The maintainer** set the objective, the audience, the scope, the reference
material, and the acceptance criteria — and decided when a result was finished.
The objective was a coherent, reviewable delivery loop in the language and
tooling from a specific job description, rather than coverage of every item in
it. The audience was a technical reviewer following public links, not someone
watching a live demo. The acceptance criterion was evidence: tests that fail
when the invariant breaks, a harness that can be shown lying, a deployment that
reads its own identity back.

**Claude Opus 5** (Anthropic, in Claude Desktop's Cowork mode) did roughly 80%
of the implementation: the gate contract, the six gates, the fault harness, the
DORA calculator and its API, the mutation-testing passes, and most of the
documentation. Every commit on `main` up to `a780e1d` here and `1eb6554` in
dora-loop is from that phase.

**Codex** (OpenAI, GPT-6 Astra) did the remaining 20%: the deployment path from
CI to a private VM, guarded rollback, the deployment-event reporter, the
operational rehearsal, and the reviewer-facing documentation. That is
delivery-gates #23–#24 and dora-loop #19–#26.

**Claude Fable 5.1** did the final public-only review that produced this page
and the cleanup of merged branches.

Neither agent wrote code unsupervised. Each change went through a branch, a
pull request opened by `tools/gh/pr-open.sh`, the gates, and a squash merge.
Codex tasks ran in separate git worktrees so several could be in flight without
touching `main`.

## The handoff was not the plan

The usual pattern is different from what happened here, and the difference is
worth stating. Normally one model builds and one or more others plan and
review, and the plan goes back and forth between them until they converge.
What gets built is the converged plan, not the first draft from either.

On this project the handoff from Claude to Codex happened mid-build because
the Anthropic plan hit its usage cap. Codex picked up from Claude's handoff
notes, the ADRs, and the wiki sources — which is the reason those live in the
repository rather than in a chat window. The continuity held well enough that
the deployment path Codex built consumes the gates Claude built without
modification, and the smoke regression suite Codex added exercises Claude's
smoke gate through the same contract.

## What the review loop caught

The gates catch what they were built to catch. Finding the defects nobody
thought of is a separate activity, and on this project it was done by pointing
a second agent at the first one's work with instructions to break it. The
[review process](Review-Process.md) page describes the mechanism; this is what
it produced, in the order it happened, with the commit that fixed each one.

- **Six routes to a wrong verdict** in the contract library, all in code that
  had already passed four gates and eighteen proofs (`0d57b2a`). The worst: the
  secret scanner could find secrets, discard them, and report PASS, because an
  abort inside process substitution happened in a subshell whose exit status
  the parent never saw.
- **The harness could be made to lie** (`309f5d9`, then again `284cb55`). A
  `fault.env` was sourced into the harness's own shell, so a fault could
  redefine the function that runs gates and fabricate every result. After the
  first fix, a second review found the digest guarding the harness tree
  covered three directories and compared once at the end — and escaped it by
  editing the unhashed paths and restoring the sabotaged gate before the
  comparison ran.
- **The scanner could be switched off** by the repository under test
  (`284cb55`). A committed `.gitleaksignore` took the secrets gate from a
  private-key finding to a clean pass, while the scanned-commit count went
  *up*. The documented fix, `--gitleaks-ignore-path`, was tried and measured
  not to work. The gate now scans a bare mirror from inside the mirror.
- **A rollback report could be accepted as a pass.** An adversarial review
  built a smoke report whose `exit_code` was 1 and got `decision=KEEP
  verification=VERIFIED` from the deployment orchestrator. Fixed in dora-loop
  before the deployment path was wired to a real target.
- **A transaction boundary that did nothing.** Both ingest methods were
  package-private, and Spring's transaction attribute source defaults to public
  methods only, so the annotation resolved no attribute and applied no
  transaction. Found by an independent review of dora-loop's API module.
- **An injectivity test that did not test injectivity.** A test named for the
  property it was meant to prove did not prove it, and two independent reviews
  found that before the maintainer did. Replaced with a pairwise check over an
  adversarial corpus (`a452427`).
- **A commit titled "stop README overclaiming" that changed two files, neither
  of them the README** — the scripted edit used a double hyphen where the file
  had an em dash, matched nothing, and reported success (`3b5e247`). That
  failure is why the `docs` gate exists.
- **Rollback published its symlink non-atomically** while activation already
  used an atomic rename. Found by a public-only review after everything else
  was merged, fixed in dora-loop #26.

Not every argument went the builder's way. The commit record for the
concurrency fixes says two independent reviews argued against the fix
originally preferred, and both were right. Two days is fast enough that the
record, not memory, is the authority on who preferred what.

## The comments are the history

The source comments are long, and many of them narrate a specific failure —
"measured", "that is not hypothetical", "it did exactly that to me". They were
written by the agents at the time each defect was found and fixed, and every
one of them was left in on purpose. They are the record of the AI build as it
happened: what was tried, what broke, what was measured, and what an
adversarial pass found afterwards — in the place a reader will actually meet
the code they describe. Read them as history, not as style. Trimming them to
conventional length would have made the repositories look more hand-written
and less true.

## What was not delegated

The agents were not trusted to decide what counted as done. Every "proven"
number in the documentation was regenerated from a clean clone rather than
accepted from a transcript, after the first transcript published was found to
have been measured against the author's working tree.

The agents never held a credential. The deployment keys, the Tailscale
identity, the GitHub token, and the ingest token were provisioned by hand and
live on the hosts that use them. Both Claude and Codex reached those hosts
through the same set of purpose-built MCP tools — the same tools from two
different desktop apps — so an agent could run a command on the build machine
or open a pull request without a secret ever entering its context. That is
also what made the mid-build handoff cheap: the second agent inherited the
tooling, not a credential bundle.

The high-level decisions — keep the service off the public internet, make the
public repositories self-contained so a reviewer needs none of the author's
infrastructure, show one coherent loop rather than every item in the job
description — were the maintainer's, worked through with the models before
implementation started rather than left for the models to make.

## What it cost

About two days of one person's attention for the build (Friday afternoon to
Sunday afternoon), plus most of the Monday for review and documentation. One
Anthropic subscription to its usage cap, and the remainder on an OpenAI
subscription. The git history records 28 commits on `main` here and 34 in
dora-loop for the build, and a handful more on the Monday. No line count is
claimed as a measure of anything.
