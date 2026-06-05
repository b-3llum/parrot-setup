# Parrot OS Red Team Setup

Automated setup script for a fully-loaded Parrot OS red team workstation. Builds on [IppSec's parrot-build](https://github.com/IppSec/parrot-build) Ansible playbook with additional C2 frameworks, pivoting tools, and post-exploitation utilities.

## What Gets Installed

### Via IppSec's Playbook (with fixes applied)
- **Docker** (modern GPG key method for Parrot/Debian trixie)
- **Impacket**, **NetExec**, **Certipy** (via pipx)
- **Evil-WinRM** (via gem)
- **Chisel**, **PEASS-ng** (linpeas/winPEAS), **Chainsaw**
- **SecLists**, **SharpCollection**, **Kerbrute**
- **Burp Suite** CA cert + jruby/jython extensions
- **VS Code** + security extensions (Python, PHP, Copilot, Snyk, Spell Checker)
- **Tmux** config, custom **bashrc**, Firefox policies
- **UFW** firewall + **Auditd/Laurel** logging
- **NOPASSWD sudo** for your user

### Additional Tools (installed by this script)
- **BloodHound CE (native)** + **neo4j** + **bloodhound.py** ingestor - installed from the `bloodhound` apt package and configured (PostgreSQL DB + neo4j password wired into `/etc/bhapi/bhapi.json`). No Docker; UI on `http://127.0.0.1:8080`.
- **AdaptixC2** - Modular red team C2 framework (Go server + extensions)
- **Havoc** - Evasion-focused C2 with Demon agent
- **Mythic** - Web-based C2 with plugin architecture (Docker)
- **Sliver** - Cross-platform C2 by BishopFox
- **Ligolo-ng** - Modern tunneling/pivoting (proxy + agent)
- **Coercer** - Windows authentication coercion tool
- **pspy** - Unprivileged Linux process monitor (32 + 64 bit)
- **Responder** (usually pre-installed on Parrot)

## Quick Start

```bash
git clone https://github.com/b-3llum/parrot-setup.git
cd parrot-setup
chmod +x parrot-setup.sh
./parrot-setup.sh
```

> Run as your normal user, NOT root. The script uses `sudo` where needed and will prompt for your password.

## Known Issues & Fixes

The script automatically patches these known issues in IppSec's playbook:

1. **`apt-key` removed from Parrot OS** - The playbook uses the deprecated `apt_key` module, but Parrot (Debian trixie) removed the `apt-key` binary entirely. Fixed by using the modern `signed-by` GPG keyring method.

2. **Docker BloodHound replaced with native** - The playbook installs BloodHound inside Docker. This script disables that task (`roles/install-tools/tasks/bloodhound.yml`) and installs the native `bloodhound` apt package instead, configuring PostgreSQL + neo4j and writing the neo4j password into `/etc/bhapi/bhapi.json`.

3. **First BloodHound launch is slow** - On the first `sudo bloodhound`, the native server builds ~230 neo4j indexes (~5 minutes) before the UI on `:8080` responds. This is normal; later starts are quick.

## Starting Services

Services are installed but **not started** by default. Start them individually:

```bash
# BloodHound (native)
sudo bloodhound          # UI: http://127.0.0.1:8080  (login admin/admin, first run ~5 min)

# Mythic
cd /opt/Mythic && sudo ./mythic-cli start
# Install an agent:
sudo ./mythic-cli install github https://github.com/MythicAgents/poseidon
sudo ./mythic-cli install github https://github.com/MythicC2Profiles/http

# AdaptixC2
cd /opt/AdaptixC2/dist && sudo bash ssl_gen.sh && sudo ./adaptixserver -p profile.yaml

# Havoc
cd /opt/Havoc && sudo ./havoc server --profile profiles/havoc.yaotl

# Sliver
sliver-server

# Ligolo-ng (on attack box)
sudo /opt/ligolo-ng/proxy -selfcert -laddr 0.0.0.0:11601

# Responder
sudo responder -I eth0 -dwPv
```

## Default Credentials

After setup, credentials are saved to `~/red-team-creds.txt`. Key ones:

| Service | Location |
|---------|----------|
| BloodHound | `http://127.0.0.1:8080` - login `admin` / `admin` (neo4j password saved in `~/red-team-creds.txt`) |
| Mythic | `cd /opt/Mythic && cat .env \| grep MYTHIC_ADMIN` |
| AdaptixC2 | `cat /opt/AdaptixC2/dist/profile.yaml` |
| Havoc | `cat /opt/Havoc/profiles/havoc.yaotl` |

## Requirements

- Parrot OS (tested on Parrot with Debian trixie/testing base)
- Internet access
- 8GB+ RAM recommended (Mythic + BloodHound are memory-hungry)
- 40GB+ disk space

## Disclaimer

This toolkit is intended for authorized penetration testing and red team engagements only. Ensure you have proper authorization before using these tools against any target. Unauthorized access to computer systems is illegal.
