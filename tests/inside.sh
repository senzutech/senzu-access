#!/usr/bin/env bash
# Runs inside a throwaway container, as root: installs the access, then checks every promise the
# setup script makes, over real SSH connections.
set -uo pipefail

SETUP=/work/senzu-access-setup.sh
HELPER=/usr/local/sbin/senzu-access
REQUEST=/var/lib/senzu-access/request
KEY=/tmp/senzu_test
failures=0

pass() { printf '  ✓ %s\n' "$1"; }
flunk() { printf '  ✗ %s\n' "$1"; failures=$((failures + 1)); }
check() { local label=$1; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else flunk "$label"; fi; }
refuse() { local label=$1; shift; if "$@" >/dev/null 2>&1; then flunk "$label"; else pass "$label"; fi; }

ssh_senzu() {
    ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 senzu@127.0.0.1 "$@"
}
as_agent() { su -s /bin/bash hermes -c "$*"; }
# A live process of senzu's, zombies excluded: a killed process may linger as a zombie until its
# new parent reaps it, and it is dead all the same.
senzu_running() { ps -u senzu -o stat=,comm= 2>/dev/null | awk -v name="$1" '$1 !~ /^Z/ && $2 == name {found=1} END {exit !found}'; }
senzu_gone() { ! senzu_running "$1"; }
# Retry a check for up to N seconds, for things that take a moment (an SSH session starting).
wait_for() { local seconds=$1; shift; for _ in $(seq "$seconds"); do "$@" && return 0; sleep 1; done; "$@"; }
# What the path unit (or cron) does when the request changes; containers have no systemd.
request() { as_agent "echo $1 > $REQUEST" && "$HELPER" sync >/dev/null; }

echo "== prerequisites"
useradd --create-home hermes
ssh-keygen -q -t ed25519 -N '' -f "$KEY"
ssh-keygen -q -t ed25519 -N '' -f /tmp/other_key
mkdir -p /run/sshd && /usr/sbin/sshd
pass "sshd running, agent user and test keys ready"

echo "== refusals"
refuse "not as root" as_agent "bash $SETUP --key-file $KEY.pub --yes"
refuse "a private key" bash "$SETUP" --key-file "$KEY" --yes
printf '%s\n%s\n' "$(cat "$KEY.pub")" "ssh-ed25519 notbase64 x" >/tmp/one_bad.pub
refuse "a good key with a bad one" bash "$SETUP" --key-file /tmp/one_bad.pub --yes
refuse "a garbage key" bash "$SETUP" --key "ssh-ed25519 notbase64 x" --yes
refuse "an unknown agent user" bash "$SETUP" --key-file "$KEY.pub" --agent-user nobody_here --yes
refuse "no --yes without a terminal" bash "$SETUP" --key-file "$KEY.pub" </dev/null
refuse "nothing installed by a refusal" getent passwd senzu

echo "== install"
check "setup succeeds" bash "$SETUP" --key-file "$KEY.pub" --yes
check "user senzu exists" getent passwd senzu
check "password locked" bash -c "passwd -S senzu | awk '{exit \$2 != \"L\"}'"
check "sudo rules valid" visudo -c
# shellcheck disable=SC2016 # evaluated by the inner bash, on purpose
check "key kept by root" bash -c '[[ $(stat -c %U:%a /etc/senzu/authorized_keys) == root:644 ]]'
check "host details recorded" grep -q '"user": "senzu"' /etc/senzu/access.json
check "closed after install" bash -c "[[ \$($HELPER status) == closed ]]"
refuse "ssh refused while closed" ssh_senzu true

echo "== the agent's rights"
refuse "agent has no sudo at all" as_agent "sudo -n -l"
check "agent can write the request" as_agent "echo closed > $REQUEST"
refuse "agent cannot remove the request file" as_agent "rm -f $REQUEST"
refuse "agent cannot forge the state" as_agent "echo open > /var/lib/senzu-access/state"
refuse "agent cannot touch the key" as_agent "echo x >> /etc/senzu/authorized_keys"
refuse "agent cannot run the command" as_agent "$HELPER on"
check "path unit installed" test -f /etc/systemd/system/senzu-access.path
check "cron safety net installed" grep -q "senzu-access sync" /etc/cron.d/senzu-access

echo "== open on request"
request open
check "status open" bash -c "[[ \$($HELPER status) == open ]]"
check "ssh accepted with the Senzu key" ssh_senzu true
check "full sudo for senzu" bash -c "[[ \$(ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null senzu@127.0.0.1 'sudo -n id -u') == 0 ]]"
refuse "another key refused" ssh -i /tmp/other_key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 senzu@127.0.0.1 true
check "a repeated request changes nothing" bash -c "[[ \$($HELPER sync) == open ]]"

echo "== close on request, with a session in progress"
ssh_senzu 'sleep 120' &
session=$!
# However slow the machine: wait for the session to be up, then for it to be gone.
check "session running" wait_for 15 senzu_running sleep
request closed
check "open session ended" wait_for 10 senzu_gone sleep
wait "$session" 2>/dev/null
check "status closed" bash -c "[[ \$($HELPER status) == closed ]]"
refuse "ssh refused after close" ssh_senzu true
check "account expired" bash -c "chage -l senzu | grep -qi 'account expires.*1970'"
check "key removed from home" bash -c "[[ ! -e /home/senzu/.ssh/authorized_keys ]]"

echo "== anything but \"open\" keeps it closed"
request open
request 'garbage'
check "garbage closes" bash -c "[[ \$($HELPER status) == closed ]]"
request 'OPEN'
check "wrong case stays closed" bash -c "[[ \$($HELPER status) == closed ]]"
as_agent ": > $REQUEST"; "$HELPER" sync >/dev/null
check "empty stays closed" bash -c "[[ \$($HELPER status) == closed ]]"

echo "== run again with a new key"
check "setup again succeeds" bash "$SETUP" --key-file /tmp/other_key.pub --yes
check "still closed" bash -c "[[ \$($HELPER status) == closed ]]"
request open
refuse "old key refused" ssh_senzu true
check "new key accepted" ssh -i /tmp/other_key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 senzu@127.0.0.1 true
check "one sudo file, for senzu only" bash -c "[[ \$(ls /etc/sudoers.d | grep -c senzu) == 1 ]]"
check "reinstall leaves it closed" bash -c "bash $SETUP --key-file /tmp/other_key.pub --yes >/dev/null && [[ \$($HELPER status) == closed ]]"

echo "== where Senzu connects"
check "an address is recorded" bash -c "grep -q '\"hostname\": \"[^\"]' /etc/senzu/access.json"
check "--host is recorded as given" bash -c "bash $SETUP --key-file /tmp/other_key.pub --host vps.example.com --yes >/dev/null && grep -q '\"hostname\": \"vps.example.com\"' /etc/senzu/access.json"

echo "== several operators"
printf '%s\n# second operator\n%s\n' "$(cat "$KEY.pub")" "$(cat /tmp/other_key.pub)" >/tmp/two_keys.pub
check "two keys accepted" bash "$SETUP" --key-file /tmp/two_keys.pub --yes
request open
check "first operator connects" ssh_senzu true
check "second operator connects" ssh -i /tmp/other_key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 senzu@127.0.0.1 true
request closed
refuse "closed for both" ssh_senzu true

echo "== uninstall"
check "uninstall succeeds" bash "$SETUP" --uninstall --yes
refuse "user gone" getent passwd senzu
refuse "command gone" test -e "$HELPER"
refuse "sudo rules gone" bash -c 'ls /etc/sudoers.d | grep -q senzu'
refuse "configuration gone" test -e /etc/senzu
refuse "request file gone" test -e /var/lib/senzu-access
refuse "units gone" test -e /etc/systemd/system/senzu-access.path
refuse "cron gone" test -e /etc/cron.d/senzu-access
check "sudo still valid" visudo -c
check "uninstall twice is harmless" bash "$SETUP" --uninstall --yes

echo
if ((failures)); then echo "$failures échec(s)"; exit 1; fi
echo "tout est passé"
