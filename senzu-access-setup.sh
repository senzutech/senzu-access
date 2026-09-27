#!/usr/bin/env bash
# Senzu maintenance access: one-time setup, run as root.
#
# Creates a named `senzu` account that Senzu reaches over SSH with its own key, and that is
# closed by default. The Hermes plugin asks for it to be opened while a paid handover is in
# progress and closed when the handover is done, by writing "open" or "closed" to one file:
#
#   /var/lib/senzu-access/request
#
# A systemd path unit (and a cron line as a safety net) applies the request as root. The Hermes
# user gets no sudo rights at all: it can ask for Senzu's access to change, nothing else.
#
# What this script does, and nothing else:
#   - creates the `senzu` user (no password, SSH key only, full sudo while open);
#   - keeps Senzu's public key in /etc/senzu, owned by root;
#   - installs /usr/local/sbin/senzu-access (on | off | status | sync);
#   - creates the request file, writable by the Hermes user, and the units that watch it;
#   - leaves the account closed.
#
# Usage:
#   sudo bash senzu-access-setup.sh [--key-url URL | --key-file PATH | --key "ssh-ed25519 …"]
#                                   [--agent-user hermes] [--yes]
#   sudo bash senzu-access-setup.sh --uninstall [--agent-user hermes] [--yes]
#
# Everything it installs is removed by --uninstall. Running it again updates the key and the
# command, and changes nothing else.

set -euo pipefail

readonly VERSION=0.1.0
readonly SENZU_USER=senzu
readonly CONF_DIR=/etc/senzu
readonly KEYS_FILE="$CONF_DIR/authorized_keys"
readonly HOST_FILE="$CONF_DIR/access.json"
readonly HELPER=/usr/local/sbin/senzu-access
readonly SUDOERS_SENZU=/etc/sudoers.d/senzu
readonly LEGACY_SUDOERS=/etc/sudoers.d/senzu-access
readonly STATE_DIR=/var/lib/senzu-access
readonly REQUEST_FILE="$STATE_DIR/request"
readonly PATH_UNIT=/etc/systemd/system/senzu-access.path
readonly SERVICE_UNIT=/etc/systemd/system/senzu-access.service
readonly CRON_FILE=/etc/cron.d/senzu-access
readonly DEFAULT_KEY_URL=https://senzu.cr.edouard.cl/ssh.pub

key_url=$DEFAULT_KEY_URL
key_file=
key_text=
agent_user=hermes
assume_yes=0
uninstall=0

say() { printf '%s\n' "$*"; }
fail() { printf 'senzu-access-setup: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,/^$/s/^# \{0,1\}//p' "$0"
    exit "${1:-0}"
}

while (($#)); do
    case "$1" in
        --key-url) key_url=${2:?--key-url needs a value}; shift 2 ;;
        --key-file) key_file=${2:?--key-file needs a value}; shift 2 ;;
        --key) key_text=${2:?--key needs a value}; shift 2 ;;
        --agent-user) agent_user=${2:?--agent-user needs a value}; shift 2 ;;
        --yes | -y) assume_yes=1; shift ;;
        --uninstall) uninstall=1; shift ;;
        --help | -h) usage 0 ;;
        --version) printf 'senzu-access-setup %s\n' "$VERSION"; exit 0 ;;
        *) printf 'senzu-access-setup: unknown option: %s\n\n' "$1" >&2; usage 2 ;;
    esac
done

[[ $(id -u) -eq 0 ]] || fail "must be run as root (sudo bash $0)"
for command in useradd userdel usermod chage passwd visudo ssh-keygen install pkill logger getent; do
    command -v "$command" >/dev/null || fail "missing command: $command"
done

confirm() {
    ((assume_yes)) && return 0
    [[ -t 0 ]] || fail "not interactive: add --yes to proceed"
    local answer
    read -r -p "$1 [o/N] " answer
    [[ $answer =~ ^[oOyY] ]] || fail "cancelled"
}

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# --- Uninstall -----------------------------------------------------------------------------------

if ((uninstall)); then
    confirm "Supprimer l'accès Senzu (utilisateur $SENZU_USER, commande, règles sudo) ?"
    [[ -x $HELPER ]] && "$HELPER" off >/dev/null 2>&1 || true
    if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
        systemctl disable --now senzu-access.path >/dev/null 2>&1 || true
    fi
    rm -f "$PATH_UNIT" "$SERVICE_UNIT" "$CRON_FILE" "$LEGACY_SUDOERS" "$SUDOERS_SENZU" "$HELPER"
    if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
        systemctl daemon-reload || true
    fi
    rm -rf "$STATE_DIR"
    if getent passwd "$SENZU_USER" >/dev/null; then
        pkill -KILL -u "$SENZU_USER" 2>/dev/null || true
        userdel -r "$SENZU_USER" 2>/dev/null || userdel "$SENZU_USER"
    fi
    rm -rf "$CONF_DIR"
    logger -t senzu-access "uninstalled"
    say "✓ Accès Senzu supprimé."
    exit 0
fi

# --- The key -------------------------------------------------------------------------------------

key_path="$scratch/senzu.pub"
if [[ -n $key_text ]]; then
    printf '%s\n' "$key_text" >"$key_path"
elif [[ -n $key_file ]]; then
    [[ -r $key_file ]] || fail "cannot read $key_file"
    cp -- "$key_file" "$key_path"
elif command -v curl >/dev/null; then
    curl -fsSL --proto '=https' --max-time 20 "$key_url" -o "$key_path" \
        || fail "cannot fetch the Senzu key from $key_url"
elif command -v wget >/dev/null; then
    wget -q --https-only -T 20 -O "$key_path" "$key_url" \
        || fail "cannot fetch the Senzu key from $key_url"
else
    fail "neither curl nor wget: pass the key with --key-file or --key"
fi

# Exactly one public key, of a sound type. A private key, or several lines, is refused.
grep -q 'PRIVATE KEY' "$key_path" && fail "that is a private key: only the public key belongs here"
[[ $(grep -cv '^[[:space:]]*$' "$key_path") -eq 1 ]] || fail "expected exactly one public key"
key_line=$(grep -v '^[[:space:]]*$' "$key_path")
[[ $key_line =~ ^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa)[[:space:]] ]] \
    || fail "unsupported key type (ed25519, ecdsa or rsa expected)"
printf '%s\n' "$key_line" >"$key_path"
fingerprint=$(ssh-keygen -l -f "$key_path") || fail "not a valid SSH public key"

getent passwd "$agent_user" >/dev/null || fail "no such user: $agent_user (use --agent-user)"

say "Accès de maintenance Senzu"
say "  utilisateur créé       : $SENZU_USER (fermé par défaut, clé SSH uniquement)"
say "  clé Senzu              : $fingerprint"
say "  ouverture / fermeture  : demandée par $agent_user dans $REQUEST_FILE, appliquée par le système"
confirm "Installer ?"

# --- The account ---------------------------------------------------------------------------------

if ! getent passwd "$SENZU_USER" >/dev/null; then
    useradd --create-home --shell /bin/bash --comment "Senzu - maintenance" "$SENZU_USER"
fi
# Never a password: the key is the only way in.
passwd --lock "$SENZU_USER" >/dev/null

install -d -m 0755 -o root -g root "$CONF_DIR"
install -m 0644 -o root -g root "$key_path" "$KEYS_FILE"

# --- sudo rules, checked before they are put in place ---------------------------------------------

install_sudoers() {
    local target=$1 content=$2 candidate="$scratch/sudoers"
    printf '%s\n' "$content" >"$candidate"
    visudo -cqf "$candidate" || fail "sudo rule refused by visudo for $target"
    install -m 0440 -o root -g root "$candidate" "$target"
}

install_sudoers "$SUDOERS_SENZU" "# Senzu maintenance: full sudo, only while the account is open.
$SENZU_USER ALL=(ALL:ALL) NOPASSWD: ALL"

# An earlier version let the agent run the command with sudo; it no longer needs any sudo.
rm -f "$LEGACY_SUDOERS"

# --- The command ---------------------------------------------------------------------------------

cat >"$scratch/senzu-access" <<'HELPER'
#!/usr/bin/env bash
# Open or close Senzu's maintenance access. Installed by senzu-access-setup.sh.
#   senzu-access on      the key is put in place and the account unlocked
#   senzu-access off     the key is removed, the account expired, open sessions ended
#   senzu-access status  prints "open" or "closed"
#   senzu-access sync    applies /var/lib/senzu-access/request ("open" or "closed");
#                        run by the senzu-access.path unit and by cron, never by the agent
set -euo pipefail
readonly SENZU_USER=senzu KEYS_FILE=/etc/senzu/authorized_keys
readonly STATE_FILE=/var/lib/senzu-access/state REQUEST_FILE=/var/lib/senzu-access/request
home=$(getent passwd "$SENZU_USER" | cut -d: -f6)
[[ -n $home ]] || { echo "senzu-access: no $SENZU_USER user" >&2; exit 1; }
group=$(id -gn "$SENZU_USER")
authorized="$home/.ssh/authorized_keys"

current() {
    if [[ -s $authorized ]] && [[ $(cat "$STATE_FILE" 2>/dev/null) == open ]]; then
        echo open
    else
        echo closed
    fi
}

open_access() {
    install -d -m 0700 -o "$SENZU_USER" -g "$group" "$home/.ssh"
    install -m 0600 -o "$SENZU_USER" -g "$group" "$KEYS_FILE" "$authorized"
    chage -E -1 "$SENZU_USER"
    echo open >"$STATE_FILE"
    logger -t senzu-access "opened ($1)"
}

close_access() {
    rm -f "$authorized"
    # Expired as well as keyless: two locks, so a key copied elsewhere does not open it.
    chage -E 0 "$SENZU_USER"
    pkill -KILL -u "$SENZU_USER" 2>/dev/null || true
    echo closed >"$STATE_FILE"
    logger -t senzu-access "closed ($1)"
}

case "${1:-}" in
    on) open_access "by ${SUDO_USER:-root}"; echo open ;;
    off) close_access "by ${SUDO_USER:-root}"; echo closed ;;
    status) current ;;
    sync)
        # Only the exact word "open" opens; anything else, garbage included, means closed.
        request=$(head -c 16 "$REQUEST_FILE" 2>/dev/null | tr -d '[:space:]') || request=
        state=$(current)
        if [[ $request == open && $state != open ]]; then
            open_access "requested by the Hermes plugin"
        elif [[ $request != open && $state != closed ]]; then
            close_access "requested by the Hermes plugin"
        fi
        current
        ;;
    *)
        echo "usage: senzu-access on|off|status|sync" >&2
        exit 2
        ;;
esac
HELPER
install -m 0755 -o root -g root "$scratch/senzu-access" "$HELPER"

# --- The request file and what watches it -------------------------------------------------------

agent_group=$(id -gn "$agent_user")
# The directory stays root's: the agent can change what the request file says, but cannot
# replace it, remove it, or touch the state file beside it.
install -d -m 0755 -o root -g root "$STATE_DIR"
[[ -f $REQUEST_FILE ]] || echo closed >"$REQUEST_FILE"
chown root:"$agent_group" "$REQUEST_FILE"
chmod 0660 "$REQUEST_FILE"

cat >"$scratch/senzu-access.service" <<'UNIT'
[Unit]
Description=Apply a Senzu maintenance access request

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/senzu-access sync
UNIT
cat >"$scratch/senzu-access.path" <<'UNIT'
[Unit]
Description=Watch Senzu maintenance access requests

[Path]
PathChanged=/var/lib/senzu-access/request

[Install]
WantedBy=multi-user.target
UNIT
install -m 0644 -o root -g root "$scratch/senzu-access.service" "$SERVICE_UNIT"
install -m 0644 -o root -g root "$scratch/senzu-access.path" "$PATH_UNIT"
# Every minute as well: a safety net if the path unit misses a change, and the only mechanism
# where systemd is absent. The sync is idempotent and logs only what it changes.
printf '%s\n' '* * * * * root /usr/local/sbin/senzu-access sync >/dev/null 2>&1' >"$scratch/cron"
install -m 0644 -o root -g root "$scratch/cron" "$CRON_FILE"
if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    systemctl enable --now senzu-access.path >/dev/null
    watcher="unité systemd senzu-access.path (et cron)"
else
    watcher="cron, chaque minute (systemd absent)"
fi

# --- Where Senzu connects: host, port, host key fingerprint ------------------------------------

port=22
if command -v sshd >/dev/null && sshd_config=$(sshd -T 2>/dev/null); then
    port=$(awk '$1 == "port" {print $2; exit}' <<<"$sshd_config")
    # sshd -T prints one "allowusers" line per allowed user.
    allow_users=$(awk '$1 == "allowusers" {printf " %s ", $2}' <<<"$sshd_config")
    if [[ -n ${allow_users// /} && $allow_users != *" $SENZU_USER "* ]]; then
        say "⚠ AllowUsers est défini dans la configuration SSH sans $SENZU_USER : ajoutez-le, sinon la connexion sera refusée."
    fi
    if awk '$1 == "pubkeyauthentication" && $2 == "no" {found=1} END {exit !found}' <<<"$sshd_config"; then
        say "⚠ PubkeyAuthentication est désactivé : l'accès par clé ne fonctionnera pas."
    fi
fi
host_key=
for candidate in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
    if [[ -r $candidate ]]; then
        host_key=$(ssh-keygen -l -f "$candidate" | awk '{print $2}')
        break
    fi
done
printf '{"hostname": "%s", "port": %s, "host_key": "%s", "user": "%s"}\n' \
    "$(hostname -f 2>/dev/null || hostname)" "${port:-22}" "$host_key" "$SENZU_USER" >"$HOST_FILE"
chmod 0644 "$HOST_FILE"

echo closed >"$REQUEST_FILE"
"$HELPER" off >/dev/null
logger -t senzu-access "version $VERSION installed for $agent_user, key $fingerprint"

say "✓ Accès Senzu installé, fermé. Il s'ouvrira pendant les interventions payées."
say "  Demandes appliquées par : $watcher"
say "  Tout retirer : sudo bash $0 --uninstall"
