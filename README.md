# Parrot OS Red Team Setup

Automated setup script for a fully-loaded Parrot OS red team workstation. Builds on [IppSec's parrot-build](https://github.com/IppSec/parrot-build) Ansible playbook with additional C2 frameworks, pivoting tools, and post-exploitation utilities.

## What Gets Installed

### Via IppSec's Playbook (with fixes applied)
- **Docker** (modern GPG key method for Parrot/Debian trixie)
- **BloodHound CE** + Neo4j (fixed password regex)
- **Impacket**, **NetExec**, **Certipy**, **BloodHound Python ingestor** (via pipx)
- **Evil-WinRM** (via gem)
- **Chisel**, **PEASS-ng** (linpeas/winPEAS), **Chainsaw**
- **SecLists**, **SharpCollection**, **Kerbrute**
- **Burp Suite** CA cert + jruby/jython extensions
- **VS Code** + security extensions (Python, PHP, Copilot, Snyk, Spell Checker)
- **Tmux** config, custom **bashrc**, Firefox policies
- **UFW** firewall + **Auditd/Laurel** logging
- **NOPASSWD sudo** for your user

### Additional Tools (installed by this script)
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

2. **BloodHound password regex mismatch** - The grep regex matches `Password Set To:` but the actual BloodHound log format is `Initial Password Set To:`. Fixed in the playbook before execution.

3. **Neo4j container health check timeout** - Neo4j 4.4 takes ~50 seconds to initialize on first run, exceeding Docker's health check. If this happens, just re-run the script.

## Starting Services

Services are installed but **not started** by default. Start them individually:

```bash
# BloodHound
cd /opt/bloodhound/server && sudo docker compose up -d

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
| BloodHound | `sudo cat /opt/bloodhound/server/initial-password.txt` |
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
