# Using it

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

## Run the non-executing gates locally

The following checks were reproduced from a fresh public clone on Linux
x86_64. They inspect documentation and shell source; they do not execute a
consumer repository's build or run the fault harness.

Prerequisites: Bash, Git, curl, jq, GNU coreutils (including sha256sum),
find, grep, sed, awk, tar and xz. ShellCheck is downloaded from GitHub and
checksum-checked by the gate. Its bundled download targets Linux x86_64;
other operating systems/architectures are not demonstrated by these commands.
No GitHub credentials or private infrastructure are required.

```bash
git clone https://github.com/jjackson0118/delivery-gates.git
cd delivery-gates
./ci/run-gate.sh ./gates/docs.sh .
./ci/run-gate.sh ./gates/shellcheck.sh .
cat .gate-reports/docs.json
cat .gate-reports/shellcheck.json
```

Expect both adapters to exit zero and each report to have `exit_code: 0`,
zero findings and a nonzero `scanned` denominator. Counts vary as files and
documentation change. Reports are written under the caller's
`.gate-reports/`; downloaded tools may use temporary directories.
The gate/adapter distinction and all four raw exit codes are described in
[The gate contract](The-Gate-Contract.md).

For checks against the companion application, clone it alongside this
repository and follow its
[local quickstart](https://github.com/jjackson0118/dora-loop/blob/main/docs/wiki/Local-Quickstart.md).
Its full Java tests additionally require JDK 21 and accessible Docker.

## Running the fault harness

Read [Proving the gates fail](Proving-Gates-Fail.md) before running
`prove-gates-fail.sh`. It executes fixture builds and fault-injection scripts;
a scratch clone protects repository files, but does not sandbox executed code.
Use a disposable environment without host credentials or unrelated services.
Do not run it as root or as an account with passwordless sudo on a shared host.
The successful local static checks above do not claim to reproduce the full
fault harness.
