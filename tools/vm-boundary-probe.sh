#!/usr/bin/env bash
# vm-boundary-probe.sh -- prove what the dora VM can and cannot reach.
#
# This script is the deliverable, not the firewall rule. The rule is one line;
# the evidence that it opened exactly that line and nothing else is the part
# worth keeping, and "I checked" is the green-standing-in-for-a-measurement
# failure this whole repository is an argument against, applied to a firewall.
#
# EVERY PROBE ASSERTS A DENOMINATOR. A refused connection and a missing `nc`
# look identical from the outside, so each block counts the probes it attempted
# and reads the corresponding DROP rule's packet counter before and after. A
# probe that failed without moving the counter did not reach the firewall, and
# is reported as INCONCLUSIVE rather than as a pass. That distinction is the
# entire point: "nothing got through" and "nothing was sent" are the two things
# this script exists to tell apart.
#
# Run as root on the host:  sudo tools/vm-boundary-probe.sh
# With --no-ufw it disables ufw for the duration and re-enables it afterwards,
# because the boundary's stated reason for living in the raw table is that it
# does not trust ufw. If that claim is true, every result is identical either
# way. If it is false, this is the run that says so.
set -uo pipefail

# Addresses come from a local, uncommitted targets file. This repository is
# public and states that it carries no fleet identifiers; tailnet peer
# addresses and a LAN gateway are exactly that. The logic here -- the
# denominator assertions, the counter reads, the ufw-off run -- is the reusable
# part and is what a reviewer needs to see. The addresses are not.
#
# The file is REQUIRED. A probe script that quietly skips the blocks it has no
# targets for would report a clean run having tested nothing, which is the
# failure this repository exists to argue about, in the script asserting a
# security boundary.
#
# Expected shape (see tools/vm-boundary-targets.example):
#   VM=dora
#   VM_IP=10.x.x.x
#   GW=10.x.x.1
#   IF=lxdbr0
#   SERVICE_PORT=8080
#   TAILNET_TARGETS="a.b.c.d:22 a.b.c.d:443"
#   LAN_TARGETS="..."
#   DOCKER_TARGETS="..."
TARGETS="${VM_BOUNDARY_TARGETS:-$(dirname "$0")/../.vm-boundary-targets}"
if [ ! -r "$TARGETS" ]; then
    echo "no targets file at $TARGETS" >&2
    echo "copy tools/vm-boundary-targets.example and fill in this host's addresses." >&2
    echo "refusing to run: a probe with no targets proves nothing." >&2
    exit 2
fi
# shellcheck source=/dev/null
. "$TARGETS"

for _req in VM VM_IP GW IF SERVICE_PORT TAILNET_TARGETS LAN_TARGETS DOCKER_TARGETS; do
    eval "_v=\${$_req:-}"
    [ -n "$_v" ] || { echo "$TARGETS does not set $_req" >&2; exit 2; }
done

PASS=0; FAIL=0; INCONCLUSIVE=0
NO_UFW=0
[ "${1:-}" = "--no-ufw" ] && NO_UFW=1

[ "$(id -u)" -eq 0 ] || { echo "must run as root (reads iptables counters)" >&2; exit 2; }
command -v lxc >/dev/null || { echo "lxc not found" >&2; exit 2; }
lxc info "$VM" >/dev/null 2>&1 || { echo "VM $VM not present" >&2; exit 2; }

# The VM needs a TCP client that reports refusal distinguishably. Established
# once, so a missing tool is an error rather than a silent pass everywhere.
if lxc exec "$VM" -- sh -c 'command -v nc' >/dev/null 2>&1; then
    IN_VM_TCP='nc -z -w2'
else
    echo "no nc inside $VM: cannot probe outbound TCP. Install netcat-openbsd." >&2
    exit 2
fi

# counter_for <destination>  -- packets matched by the lxdbr0 DROP for that dest.
#
# Matched on columns, not by regex over the whole line. With --line-numbers the
# layout is fixed: 1=num 2=pkts 3=bytes 4=target 5=prot 6=opt 7=in 8=out
# 9=source 10=destination. The first version regexed the line, matched nothing,
# and the script reported INCONCLUSIVE rather than a pass -- which is the whole
# reason it separates those two verdicts.
counter_for() {
    iptables -t raw -L PREROUTING -v -x -n --line-numbers 2>/dev/null \
        | awk -v dest="$1" '$4=="DROP" && $7=="lxdbr0" && $10==dest {print $2; exit}'
}

report() { # report <verdict> <label> <detail>
    case "$1" in
        PASS) PASS=$((PASS+1));         printf '  PASS         %-42s %s\n' "$2" "$3" ;;
        FAIL) FAIL=$((FAIL+1));         printf '  FAIL         %-42s %s\n' "$2" "$3" ;;
        *)    INCONCLUSIVE=$((INCONCLUSIVE+1)); printf '  INCONCLUSIVE %-42s %s\n' "$2" "$3" ;;
    esac
}

# blocked_block <label> <counter-pattern> <host:port>...
#
# Asserts every probe was refused AND that the named DROP rule's counter rose by
# the number of probes attempted. The counter is what separates "the firewall
# stopped it" from "nothing was sent".
blocked_block() {
    local label="$1" dest="$2"; shift 2
    local before after attempted=0 got_through=0 target
    before="$(counter_for "$dest")"
    [ -n "$before" ] || { report INCONCLUSIVE "$label" "no lxdbr0 DROP for $dest in raw/PREROUTING"; return; }
    for target in "$@"; do
        attempted=$((attempted+1))
        if lxc exec "$VM" -- sh -c "$IN_VM_TCP ${target%:*} ${target##*:}" >/dev/null 2>&1; then
            got_through=$((got_through+1))
            printf '                 !! REACHED %s\n' "$target"
        fi
    done
    after="$(counter_for "$dest")"
    local moved=$(( after - before ))
    if [ "$got_through" -ne 0 ]; then
        report FAIL "$label" "$got_through of $attempted probes REACHED the target"
    elif [ "$moved" -lt "$attempted" ]; then
        report INCONCLUSIVE "$label" \
            "$attempted probes refused, but the DROP counter moved by $moved -- not all reached the firewall"
    else
        report PASS "$label" "$attempted/$attempted refused, DROP counter +$moved"
    fi
}

printf '\n=== dora VM boundary, %s ===\n' "$(date -u +%FT%TZ)"
printf 'ufw: %s%s\n\n' "$(ufw status 2>/dev/null | head -1)" \
    "$([ "$NO_UFW" -eq 1 ] && printf '  (about to be DISABLED for this run)')"

if [ "$NO_UFW" -eq 1 ]; then
    UFW_WAS="$(ufw status | head -1)"
    ufw --force disable >/dev/null
    trap 'ufw --force enable >/dev/null; echo; echo "ufw re-enabled: $(ufw status | head -1)"' EXIT
    printf 'ufw disabled for the duration. The boundary claims not to depend on it.\n\n'
fi

printf -- '-- what must still be blocked --\n'
# shellcheck disable=SC2086  # the target lists are space-separated on purpose
blocked_block "tailnet"        "100.64.0.0/10" $TAILNET_TARGETS
# shellcheck disable=SC2086
blocked_block "LAN"            "192.168.0.0/16" $LAN_TARGETS
# shellcheck disable=SC2086
blocked_block "docker bridges" "172.16.0.0/12" $DOCKER_TARGETS
blocked_block "host services"  "$GW" \
    "${GW}:22" "${GW}:8100" "${GW}:8101"

printf -- '\n-- the adversarial probe: the exact surface the new rule creates --\n'
# The RETURN admits sport 8080 from the VM. If it were written without ! --syn,
# the VM could open connections to any host port from that source port. This is
# the probe that tests the rule as written rather than as intended, and skipping
# it means the rule is untested.
# nc -p binds the source port for real -- verified by connecting out to
# 1.1.1.1:443 with -p 8080 (succeeded) and immediately again (bind failed:
# address already in use). A bind failure is reported as INCONCLUSIVE and never
# as a pass: "could not send" and "was refused" are the two things this script
# exists to keep apart, and here they differ by one line of stderr.
src_ok=0; src_tried=0; src_bindfail=0
for p in 22 8100 8101; do
    src_tried=$((src_tried+1))
    out=""
    for _try in 1 2 3; do
        out="$(lxc exec "$VM" -- sh -c \
            "nc -p ${SERVICE_PORT} -z -w3 ${GW} ${p} 2>&1; echo rc=\$?" 2>/dev/null)"
        case "$out" in *"bind failed"*) sleep 5 ;; *) break ;; esac
    done
    case "$out" in
        *"bind failed"*) src_bindfail=$((src_bindfail+1)) ;;
        *rc=0*)          src_ok=$((src_ok+1))
                         printf '                 !! REACHED %s:%s from source port %s\n' \
                             "$GW" "$p" "$SERVICE_PORT" ;;
    esac
    sleep 1
done
if [ "$src_ok" -ne 0 ]; then
    report FAIL "VM->host from sport $SERVICE_PORT" "$src_ok of $src_tried REACHED -- the rule admits VM-initiated traffic"
elif [ "$src_bindfail" -ne 0 ]; then
    report INCONCLUSIVE "VM->host from sport $SERVICE_PORT" \
        "$src_bindfail of $src_tried could not bind the source port -- those probes proved nothing"
else
    report PASS "VM->host from sport $SERVICE_PORT" "$src_tried/$src_tried refused"
fi

printf -- '\n-- what must work --\n'
if curl -sS -m5 -o /dev/null -w '%{http_code}' "http://${VM_IP}:${SERVICE_PORT}/actuator/health" 2>/dev/null | grep -q '^[23]'; then
    report PASS "host -> VM:${SERVICE_PORT}" "reachable"
elif nc -z -w3 "$VM_IP" "$SERVICE_PORT" 2>/dev/null; then
    report PASS "host -> VM:${SERVICE_PORT}" "TCP open (no HTTP service yet)"
else
    report INCONCLUSIVE "host -> VM:${SERVICE_PORT}" \
        "no answer -- expected until the rule lands AND something listens on :${SERVICE_PORT}"
fi

# ICMP is deliberately NOT opened. Recorded so nobody later "fixes" ping and
# widens the rule to do it.
if ping -c1 -W2 "$VM_IP" >/dev/null 2>&1; then
    report FAIL "host -> VM ICMP" "ping SUCCEEDED -- the rule is wider than written"
else
    report PASS "host -> VM ICMP" "still blocked, as designed"
fi

if lxc exec "$VM" -- sh -c 'command -v curl >/dev/null && curl -sS -m8 -o /dev/null -w "%{http_code}" https://ghcr.io/v2/' 2>/dev/null | grep -qE '^[2-4]'; then
    report PASS "VM -> public internet" "ghcr.io answered"
else
    report INCONCLUSIVE "VM -> public internet" "no answer (curl missing, or egress broken)"
fi

printf -- '\n-- IPv6 --\n'
if ip -6 addr show "$IF" 2>/dev/null | grep -q 'inet6 [^f]'; then
    report FAIL "IPv6 on $IF" "a global address is present; the v6 drops must be re-verified"
else
    v6rules=$(ip6tables -t raw -S PREROUTING 2>/dev/null | grep -c "$IF")
    report PASS "IPv6 on $IF" "no global address; $v6rules ip6tables drops staged for re-enablement"
fi

printf '\n=== %d passed, %d failed, %d inconclusive ===\n' "$PASS" "$FAIL" "$INCONCLUSIVE"
[ "$FAIL" -eq 0 ] && [ "$INCONCLUSIVE" -eq 0 ] && exit 0
[ "$FAIL" -ne 0 ] && exit 1
exit 2
