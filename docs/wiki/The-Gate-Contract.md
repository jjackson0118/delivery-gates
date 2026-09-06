# The gate contract

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
