# The gates

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

**`smoke`** — verifies a deployed service actually serves, and serves the build
that was deployed. A deploy step's exit code says the commands ran; it does not
say the service came up, and it does not say the service that came up is the one
you shipped. Both were observed failing during a manual deploy rehearsal on
`dora-loop`: a release whose symlink flipped and whose unit restarted, reporting
the *previous* release's build identity, from a deploy that returned 0.

Three checks, each of which has been observed failing: the service becomes ready
within a stated budget; `/actuator/info` reports the identity the deploy shipped
(`SMOKE_EXPECT_SHA`); and a real product endpoint answers correctly rather than
a health endpoint written to return 200. For `dora-loop` that last one asserts a
report for an unknown service reads `UNOBSERVED` — a deployment serving a
confident `0` instead is serving something that violates the contract it exists
to enforce.

The `1`/`2` split does more work here than anywhere else, because the caller
does different things with them. Exit 1 means the service answered and the
answer was wrong: roll back. Exit 2 means the gate could not find out, so the
deploy must be reported as neither good nor bad. A caller treating "non-zero" as
"roll back" will roll back a healthy release because `curl` was missing; one
treating it as "failed" will report a change failure that never happened.

Connection refused is a **finding**, not an error: nothing listening where the
service should be is exactly what smoke looks for. That was wrong in the first
version — the contract library runs under `set -eE`, so a failing `curl` tripped
the ERR trap and returned exit 2, contradicting the mapping documented in the
gate's own header. The fault sweep caught it; reading it did not.

No `SMOKE_URL` means exit 3, not applicable: a repository that builds but does
not deploy has not suffered a broken gate. That is safe only because exit 3 maps
to success for the orchestrator and a fixture must therefore *declare* `smoke`
in its floors file — without the declaration, forgetting to set `SMOKE_URL`
would turn the smoke stage into a green no-op, which is this repository's
central complaint arriving through its own newest gate.

