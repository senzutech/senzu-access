<div align="center">

# senzu-access

**Maintenance access for Senzu, open only while an intervention is paid for and in progress.**

[![CI](https://github.com/senzutech/senzu-access/actions/workflows/ci.yml/badge.svg)](https://github.com/senzutech/senzu-access/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/senzutech/senzu-access?sort=semver)](https://github.com/senzutech/senzu-access/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Shell](https://img.shields.io/badge/bash-shellcheck%20clean-4EAA25)
![Tested on](https://img.shields.io/badge/tested%20on-Debian%2012%20·%20Ubuntu%2022.04%20·%2024.04-orange)

[Website](https://senzu.tech) · [Install](#install) · [How it works](#how-it-works) · [Security](#security-model) · [Hermes plugin](https://github.com/senzutech/hermes-plugin-senzu)

</div>

---

[Senzu](https://senzu.tech) maintains servers that run a Hermes assistant. Some interventions
need the machine itself: installing a language runtime, Docker, a headless browser. This tool
gives Senzu that access the way managed-services providers do it, and closes it the rest of the
time:

- a **named `senzu` account**, never a shared root password;
- **SSH keys only**, one per Senzu operator (a person, an agent), no password ever;
- **full sudo while open**, because installing software needs it;
- **closed by default**: opened while a paid Senzu handover is in progress, closed when it is
  done, automatically, by the [Hermes plugin](https://github.com/senzutech/hermes-plugin-senzu);
- **the Hermes user gets no sudo at all**: it can only ask for Senzu's access to change;
- **everything is logged** on your machine, and you can remove it all at any time.

## Install

Once per machine, as root:

```bash
curl -fsSLO https://github.com/senzutech/senzu-access/releases/latest/download/senzu-access-setup.sh
curl -fsSLO https://github.com/senzutech/senzu-access/releases/latest/download/senzu-access-setup.sh.sha256
sha256sum -c senzu-access-setup.sh.sha256
sudo bash senzu-access-setup.sh
```

It shows what it will do and the fingerprint of each Senzu key, and asks before doing it. Options:

| Option | Default | |
|---|---|---|
| `--agent-user USER` | `hermes` | The user the Hermes plugin runs as |
| `--key-url URL` | Senzu's published keys | Where to fetch Senzu's public keys (one per line, eight at most) |
| `--key-file PATH`, `--key "ssh-ed25519 …"` | | Give the keys directly instead |
| `--yes` | | No confirmation (scripted installs) |
| `--uninstall` | | Remove everything this installed |

Running it again updates the keys (a new Senzu operator, a revoked one) and the tooling, and
leaves the access closed.

## How it works

```text
paid handover in progress ─► Hermes plugin writes "open"  ─► /var/lib/senzu-access/request
                                                              │ systemd path unit (+ cron each minute)
                                                              ▼
                                  senzu-access sync (root): key in place, account unlocked
handover done ─────────────► plugin writes "closed" ─► key removed, account expired, sessions ended
```

| Installed | Owner, mode | Role |
|---|---|---|
| user `senzu` | password locked | The account Senzu logs in as |
| `/etc/senzu/authorized_keys` | root, 0644 | Senzu's public keys, copied in only while open |
| `/etc/senzu/access.json` | root, 0644 | Host name, SSH port, host key fingerprint, reported to Senzu |
| `/etc/sudoers.d/senzu` | root, 0440 | `senzu ALL=(ALL:ALL) NOPASSWD: ALL`, checked by `visudo` |
| `/usr/local/sbin/senzu-access` | root, 0755 | `on`, `off`, `status`, `sync` |
| `/var/lib/senzu-access/request` | root:hermes, 0660 | The only thing the agent can write: `open` or `closed` |
| `/var/lib/senzu-access/state` | root, 0644 | What was last applied |
| `senzu-access.path`, `.service` | systemd | Apply a request as soon as it is written |
| `/etc/cron.d/senzu-access` | root | The same, every minute, as a safety net |

You can open or close it yourself at any time: `sudo senzu-access on`, `sudo senzu-access off`.

## Security model

- **Two locks when closed.** The keys are removed from the account *and* the account is expired,
  so a copy of a key elsewhere does not open it. Closing also ends open sessions.
- **The agent can only ask.** It may change the word in the request file; it cannot replace or
  remove that file, write the state, touch the key or run anything as root. Anything but the
  exact word `open` means closed.
- **No shared secret.** Senzu's private keys never leave their owners; this machine only holds
  public keys, one per operator, so one can be revoked without the others.
- **Traceability.** Every opening and closing goes to syslog (`journalctl -t senzu-access`),
  every `sudo` by `senzu` to the auth log, and each change is reported to Senzu with the
  handover it served.
- **Revocable.** `sudo bash senzu-access-setup.sh --uninstall` removes the account and everything
  listed above.

Please report vulnerabilities privately, see [SECURITY.md](SECURITY.md).

## Development

```bash
shellcheck senzu-access-setup.sh tests/*.sh
tests/run.sh                  # Debian 12 and Ubuntu 24.04 containers, real SSH connections
tests/run.sh ubuntu:22.04     # or any other image
```

The tests install the access, then check every promise above over real SSH connections:
refusals, the agent's rights, opening, closing with a session in progress, reinstalling with a
new key, uninstalling.

## License

[MIT](LICENSE) © Senzu
