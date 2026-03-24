#!/usr/bin/env bash
#
# VM setup script — hardened baseline with auto-updates and Claude Code.
# Supports Ubuntu, Debian, and Amazon Linux.
# Run as a regular user with sudo access (not root).
# Prerequisites: sudo must be installed (Debian minimal: run `su -c "apt install sudo"` first).
#
# Supports resume after reboot or cancellation: tracks completed steps and
# picks up where it left off. Safe to re-run at any point.
#
# One-liner: curl -fsSL https://YOUR_HOST/setup-vm.sh -o ~/setup-vm.sh && bash ~/setup-vm.sh

set -euo pipefail

SCRIPT_PATH="$(realpath "$0")"
STATE_FILE="$HOME/.setup-vm-state"
SKIP_FILE="$HOME/.setup-vm-skip"
RESUME_MARKER="# __setup-vm-resume__"
USERNAME="${USER}"

# ── Detect package manager and distro ────────────────────────────────────────
if command -v apt-get &>/dev/null; then
  PKG_MGR="apt"
elif command -v dnf &>/dev/null; then
  PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
  PKG_MGR="yum"
else
  echo "Error: No supported package manager found (apt, dnf, yum)." >&2
  exit 1
fi

. /etc/os-release
DISTRO_ID="${ID}"

pkg_update() {
  case "$PKG_MGR" in
    apt) sudo apt update && sudo apt upgrade -y ;;
    dnf) sudo dnf upgrade -y ;;
    yum) sudo yum update -y ;;
  esac
}

pkg_install() {
  case "$PKG_MGR" in
    apt) sudo apt install -y "$@" ;;
    dnf) sudo dnf install -y "$@" ;;
    yum) sudo yum install -y "$@" ;;
  esac
}

# ── Step definitions ─────────────────────────────────────────────────────────
STEP_LABELS=(
  [1]="System update"
  [2]="Essential packages"
  [3]="Docker Engine"
  [4]="Auto-updates"
  [5]="SSH hardening"
  [6]="Firewall"
  [7]="fail2ban"
  [8]="Passwordless sudo"
  [9]="Tailscale"
  [10]="GitHub CLI"
  [11]="GitHub auth + Git config"
  [12]="Node.js LTS"
  [13]="PATH setup"
  [14]="Claude Code"
  [15]="Claude Code authentication"
  [16]="GabayAI bootstrap"
  [17]="Code directory"
)
TOTAL_STEPS=17

MENU_ITEMS=(
  "3|Docker Engine + Compose"
  "4|Auto-updates (all packages, auto-reboot 3am EST)"
  "5|SSH hardening (disable root login + password auth)"
  "6|Firewall (deny incoming, rate-limit SSH)"
  "7|fail2ban (SSH brute-force protection)"
  "8|Passwordless sudo for current user"
  "9|Tailscale (mesh VPN with SSH enabled)"
  "10|GitHub CLI + auth + git identity"
  "12|Node.js LTS (via NodeSource repo)"
  "14|Claude Code (AI coding assistant)"
)

declare -A STEP_DEPS=( [11]=10 )

# ── State management ───────────────────────────────────────────────────────
get_step() { cat "$STATE_FILE" 2>/dev/null || echo "0"; }
set_step() { echo "$1" > "$STATE_FILE"; }
step_done() { [ "$(get_step)" -ge "$1" ]; }
step_skipped() { grep -qx "$1" "$SKIP_FILE" 2>/dev/null; }

install_resume_hook() {
  if ! grep -qF "$RESUME_MARKER" "$HOME/.bash_profile" 2>/dev/null; then
    cat >> "$HOME/.bash_profile" <<EOF
if [ -f "$STATE_FILE" ]; then bash "$SCRIPT_PATH"; fi $RESUME_MARKER
EOF
  fi
}

remove_resume_hook() {
  if [ -f "$HOME/.bash_profile" ]; then
    sed -i "/$RESUME_MARKER/d" "$HOME/.bash_profile"
  fi
  rm -f "$STATE_FILE" "$SKIP_FILE"
}

reboot_if_needed() {
  local needs_reboot=false
  if [ -f /var/run/reboot-required ]; then
    needs_reboot=true
  elif command -v needs-restarting &>/dev/null && ! needs-restarting -r &>/dev/null; then
    needs_reboot=true
  fi
  if [ "$needs_reboot" = true ]; then
    echo ""
    echo "==> Reboot required (likely kernel upgrade). Rebooting in 5 seconds..."
    echo "    The setup will resume automatically on next login."
    install_resume_hook
    sleep 5
    sudo reboot
    exit 0
  fi
}

# ── Summary on exit ────────────────────────────────────────────────────────
print_summary() {
  local completed
  completed="$(get_step)"
  echo ""
  echo "============================================"
  echo "  Setup summary"
  echo "============================================"
  for i in $(seq 1 $TOTAL_STEPS); do
    if step_skipped "$i"; then
      echo "  [skip]  $i. ${STEP_LABELS[$i]}"
    elif [ "$i" -le "$completed" ]; then
      echo "  [done]  $i. ${STEP_LABELS[$i]}"
    else
      echo "  [    ]  $i. ${STEP_LABELS[$i]}"
    fi
  done
  echo "============================================"
  if [ "$completed" -ge "$TOTAL_STEPS" ]; then
    echo "  All steps complete!"
  else
    echo "  Re-run to continue from step $((completed + 1))."
    echo "  bash $SCRIPT_PATH"
  fi
  echo "============================================"
}
trap print_summary EXIT

# ── Interactive menu ─────────────────────────────────────────────────────────
show_menu() {
  local menu_size=${#MENU_ITEMS[@]}
  local cursor=0
  local -a selected
  for ((i=0; i<menu_size; i++)); do selected[$i]=1; done

  echo ""
  echo "============================================"
  echo "  VM Setup Script"
  echo "============================================"
  echo ""
  echo "  This script sets up a fresh Linux VM with"
  echo "  a hardened, production-ready baseline:"
  echo ""
  echo "  - System update + essential packages"
  echo "  - Security hardening (SSH, firewall, fail2ban)"
  echo "  - Auto-updates with scheduled reboots"
  echo "  - Docker, Node.js, GitHub CLI"
  echo "  - Tailscale mesh VPN"
  echo "  - Claude Code AI assistant"
  echo ""
  echo "  Detected: ${DISTRO_ID} (${PKG_MGR})"
  echo ""
  echo "  Prerequisites:"
  echo "    - GitHub account (free: https://github.com/signup)"
  echo "    - Tailscale account (free: https://tailscale.com)"
  echo "  If you don't have these yet, uncheck those"
  echo "  steps below and re-run the script later."
  echo ""
  echo "  Use the menu below to customize."
  echo "  Core steps (update, PATH setup) always run."
  echo ""
  echo "  Controls:"
  echo "    Up/Down  Move cursor"
  echo "    Space    Toggle item"
  echo "    a        Toggle all"
  echo "    Enter    Confirm and start"
  echo "    q        Quit"
  echo ""

  draw_menu() {
    if [ "${1:-}" = "redraw" ]; then
      printf '\033[%dA' "$menu_size"
    fi
    for ((i=0; i<menu_size; i++)); do
      local label="${MENU_ITEMS[$i]#*|}"
      local mark=" "
      if [ "${selected[$i]}" -eq 1 ]; then mark="x"; fi
      if [ "$i" -eq "$cursor" ]; then
        printf '\033[1m  > [%s] %s\033[0m\n' "$mark" "$label"
      else
        printf '    [%s] %s\n' "$mark" "$label"
      fi
    done
  }

  draw_menu

  while true; do
    IFS= read -rsn1 key
    case "$key" in
      $'\x1b')
        read -rsn2 rest
        case "$rest" in
          '[A') ((cursor > 0)) && ((cursor--)) ;;
          '[B') ((cursor < menu_size - 1)) && ((cursor++)) ;;
        esac
        ;;
      ' ')
        if [ "${selected[$cursor]}" -eq 1 ]; then
          selected[$cursor]=0
        else
          selected[$cursor]=1
        fi
        ;;
      'a')
        local all_on=1
        for ((i=0; i<menu_size; i++)); do
          if [ "${selected[$i]}" -eq 0 ]; then all_on=0; break; fi
        done
        for ((i=0; i<menu_size; i++)); do
          if [ "$all_on" -eq 1 ]; then selected[$i]=0; else selected[$i]=1; fi
        done
        ;;
      ''|$'\n')
        break
        ;;
      'q')
        echo ""
        echo "Aborted."
        trap - EXIT
        exit 0
        ;;
    esac
    draw_menu redraw
  done

  local -A selected_steps
  for ((i=0; i<menu_size; i++)); do
    local step_num="${MENU_ITEMS[$i]%%|*}"
    if [ "${selected[$i]}" -eq 1 ]; then
      selected_steps[$step_num]=1
    fi
  done

  if [ "${selected_steps[10]:-0}" -eq 1 ]; then
    selected_steps[11]=1
  fi

  : > "$SKIP_FILE"
  for i in $(seq 1 $TOTAL_STEPS); do
    case "$i" in 1|2|13|15|16|17) continue ;; esac
    if [ "$i" -eq 11 ] && [ "${selected_steps[10]:-0}" -eq 0 ]; then
      echo "$i" >> "$SKIP_FILE"
      continue
    fi
    if [ "${selected_steps[$i]:-0}" -ne 1 ]; then
      echo "$i" >> "$SKIP_FILE"
    fi
  done

  echo ""
  echo "==> Starting setup for user: ${USERNAME}"
  echo ""
}

# ── Show menu on first run, skip on resume ────────────────────────────────
STEP="$(get_step)"
if [ "$STEP" -eq 0 ]; then
  show_menu
else
  echo "==> Resuming setup from step $((STEP + 1)): ${STEP_LABELS[$((STEP + 1))]}"
fi

# ── Helper: run or skip ──────────────────────────────────────────────────────
run_step() {
  local n=$1
  if step_done "$n"; then return 0; fi
  if step_skipped "$n"; then
    echo "    [skip] $n. ${STEP_LABELS[$n]}"
    set_step "$n"
    return 0
  fi
  return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# STEPS
# ══════════════════════════════════════════════════════════════════════════════

# ── 1. System update ────────────────────────────────────────────────────────
if ! step_done 1; then
  echo "==> [1/$TOTAL_STEPS] Updating system packages..."
  pkg_update
  set_step 1
fi

# ── 2. Essential packages ───────────────────────────────────────────────────
if ! step_done 2; then
  echo "==> [2/$TOTAL_STEPS] Installing essentials..."
  case "$PKG_MGR" in
    apt)
      pkg_install tmux python3 python3-pip python3-venv python3-dev \
        fail2ban curl wget git sqlite3 ufw ca-certificates gnupg \
        openssh-server update-notifier-common
      ;;
    dnf|yum)
      # EPEL is needed for fail2ban and other extras
      if [ "$DISTRO_ID" = "amzn" ]; then
        pkg_install amazon-linux-extras 2>/dev/null || true
        sudo amazon-linux-extras install epel -y 2>/dev/null || pkg_install epel-release 2>/dev/null || true
      else
        pkg_install epel-release 2>/dev/null || true
      fi
      pkg_install tmux python3 python3-pip python3-devel \
        fail2ban curl wget git sqlite ca-certificates gnupg2 \
        openssh-server yum-utils firewalld
      ;;
  esac
  set_step 2
fi

# ── 3. Docker Engine + Compose ──────────────────────────────────────────────
if ! run_step 3; then
  echo "==> [3/$TOTAL_STEPS] Installing Docker..."
  case "$PKG_MGR" in
    apt)
      DOCKER_DISTRO="${DISTRO_ID}"
      DOCKER_CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
      sudo install -m 0755 -d /etc/apt/keyrings
      sudo curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
      sudo chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/${DOCKER_DISTRO} ${DOCKER_CODENAME} stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      sudo apt update
      pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    dnf|yum)
      sudo "$PKG_MGR" config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null \
        || sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      sudo systemctl enable docker
      sudo systemctl start docker
      ;;
  esac
  sudo usermod -aG docker "${USERNAME}"
  set_step 3
fi

# ── 4. Auto-updates ─────────────────────────────────────────────────────────
if ! run_step 4; then
  echo "==> [4/$TOTAL_STEPS] Configuring auto-updates..."
  case "$PKG_MGR" in
    apt)
      pkg_install unattended-upgrades
      sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'AUTOUPGRADE'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTOUPGRADE

      sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null <<'UUCONF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
    "${distro_id}:${distro_codename}-updates";
    "${distro_id}:${distro_codename}-backports";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
UUCONF
      ;;
    dnf)
      pkg_install dnf-automatic
      sudo sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/dnf/automatic.conf
      sudo sed -i 's/^upgrade_type.*/upgrade_type = default/' /etc/dnf/automatic.conf
      sudo systemctl enable --now dnf-automatic.timer
      ;;
    yum)
      pkg_install yum-cron
      sudo sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/yum/yum-cron.conf
      sudo sed -i 's/^update_cmd.*/update_cmd = default/' /etc/yum/yum-cron.conf
      sudo systemctl enable --now yum-cron
      ;;
  esac

  sudo timedatectl set-timezone America/New_York
  set_step 4
fi

# ── 5. SSH hardening ────────────────────────────────────────────────────────
if ! run_step 5; then
  echo "==> [5/$TOTAL_STEPS] Hardening SSH..."
  # sshd_config.d is supported on modern distros; fall back to main config
  if [ -d /etc/ssh/sshd_config.d ]; then
    sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<'SSHD'
PermitRootLogin no
PasswordAuthentication no
SSHD
  else
    sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  fi
  if systemctl cat sshd.service &>/dev/null; then
    sudo systemctl restart sshd
  else
    sudo systemctl restart ssh
  fi
  set_step 5
fi

# ── 6. Firewall ─────────────────────────────────────────────────────────────
if ! run_step 6; then
  echo "==> [6/$TOTAL_STEPS] Configuring firewall..."
  case "$PKG_MGR" in
    apt)
      sudo ufw default deny incoming
      sudo ufw default allow outgoing
      sudo ufw limit OpenSSH
      echo "y" | sudo ufw enable
      ;;
    dnf|yum)
      sudo systemctl enable --now firewalld
      sudo firewall-cmd --permanent --set-default-zone=drop
      sudo firewall-cmd --permanent --add-service=ssh
      # Rate-limit SSH via fail2ban (firewalld doesn't have built-in rate limiting)
      sudo firewall-cmd --reload
      ;;
  esac
  set_step 6
fi

# ── 7. fail2ban ─────────────────────────────────────────────────────────────
if ! run_step 7; then
  echo "==> [7/$TOTAL_STEPS] Configuring fail2ban..."
  sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
  # On firewalld systems, tell fail2ban to use firewalld
  if [ "$PKG_MGR" != "apt" ] && command -v firewall-cmd &>/dev/null; then
    sudo sed -i 's/^banaction\s*=.*/banaction = firewallcmd-ipset/' /etc/fail2ban/jail.local
  fi
  sudo systemctl enable fail2ban
  sudo systemctl restart fail2ban
  set_step 7
fi

# ── 8. Passwordless sudo ────────────────────────────────────────────────────
if ! run_step 8; then
  echo "==> [8/$TOTAL_STEPS] Setting up passwordless sudo for ${USERNAME}..."
  echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/${USERNAME}" > /dev/null
  sudo chmod 440 "/etc/sudoers.d/${USERNAME}"
  set_step 8
  reboot_if_needed
fi

# ── 9. Tailscale ────────────────────────────────────────────────────────────
if ! run_step 9; then
  echo "==> [9/$TOTAL_STEPS] Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo tailscale up --ssh --accept-routes
  # Tailscale network performance optimization (networkd-dispatcher is Debian/Ubuntu only)
  if [ "$PKG_MGR" = "apt" ]; then
    sudo mkdir -p /etc/networkd-dispatcher/routable.d
    sudo tee /etc/networkd-dispatcher/routable.d/50-tailscale > /dev/null <<'TSOPT'
#!/bin/sh
ethtool -K "$(ip -o route get 1.1.1.1 | cut -f 5 -d ' ')" rx-udp-gro-forwarding on rx-gro-list off
TSOPT
    sudo chmod 755 /etc/networkd-dispatcher/routable.d/50-tailscale
  else
    # On RPM distros, use a NetworkManager dispatcher script
    sudo mkdir -p /etc/NetworkManager/dispatcher.d
    sudo tee /etc/NetworkManager/dispatcher.d/50-tailscale > /dev/null <<'TSOPT'
#!/bin/sh
[ "$2" = "up" ] || exit 0
ethtool -K "$1" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || true
TSOPT
    sudo chmod 755 /etc/NetworkManager/dispatcher.d/50-tailscale
  fi
  set_step 9
fi

# ── 10. GitHub CLI ──────────────────────────────────────────────────────────
if ! run_step 10; then
  echo "==> [10/$TOTAL_STEPS] Installing GitHub CLI..."
  case "$PKG_MGR" in
    apt)
      (type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
        && sudo mkdir -p -m 755 /etc/apt/keyrings \
        && out=$(mktemp) && wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        && cat "$out" | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
        && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
           | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
        && sudo apt update \
        && pkg_install gh
      ;;
    dnf|yum)
      sudo "$PKG_MGR" config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo 2>/dev/null \
        || sudo yum-config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
      pkg_install gh
      ;;
  esac
  set_step 10
fi

# ── 11. GitHub auth + Git config ────────────────────────────────────────────
if ! run_step 11; then
  echo "==> [11/$TOTAL_STEPS] Authenticating with GitHub..."
  if ! gh auth status &>/dev/null; then
    gh auth login
  else
    echo "    Already authenticated as $(gh api user --jq '.login')"
  fi
  git config --global init.defaultBranch main
  GH_NAME="$(gh api user --jq '.name')"
  GH_EMAIL="$(gh api user --jq '.email // empty')"
  if [ -z "$GH_EMAIL" ]; then
    GH_ID="$(gh api user --jq '.id')"
    GH_LOGIN="$(gh api user --jq '.login')"
    GH_EMAIL="${GH_ID}+${GH_LOGIN}@users.noreply.github.com"
  fi
  git config --global user.name "$GH_NAME"
  git config --global user.email "$GH_EMAIL"
  echo "    Git identity: ${GH_NAME} <${GH_EMAIL}>"
  set_step 11
fi

# ── 12. Node.js LTS (via NodeSource repo) ────────────────────────────────────
if ! run_step 12; then
  echo "==> [12/$TOTAL_STEPS] Installing Node.js LTS..."
  case "$PKG_MGR" in
    apt)
      sudo mkdir -p /etc/apt/keyrings
      curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
      echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        | sudo tee /etc/apt/sources.list.d/nodesource.list > /dev/null
      sudo apt update
      pkg_install nodejs
      ;;
    dnf|yum)
      curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
      pkg_install nodejs
      ;;
  esac
  set_step 12
fi

# ── 13. PATH setup ──────────────────────────────────────────────────────────
if ! step_done 13; then
  echo "==> [13/$TOTAL_STEPS] Configuring PATH..."
  if ! grep -q 'HOME/.local/bin' "$HOME/.bashrc"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
  fi
  export PATH="$HOME/.local/bin:$PATH"
  set_step 13
fi

# ── 14. Claude Code ─────────────────────────────────────────────────────────
if ! run_step 14; then
  echo "==> [14/$TOTAL_STEPS] Installing Claude Code..."
  export PATH="$HOME/.local/bin:$PATH"
  curl -fsSL https://claude.ai/install.sh | bash -s stable
  set_step 14
fi

# ── 15. Claude Code authentication ────────────────────────────────────────
if ! step_done 15; then
  if command -v claude &>/dev/null; then
    echo "==> [15/$TOTAL_STEPS] Authenticating Claude Code..."
    echo ""
    echo "    To get a permanent API token, run this command in a"
    echo "    separate terminal (or open a new SSH session):"
    echo ""
    echo "      claude setup-token"
    echo ""
    echo "    Follow the prompts there — it will give you a token."
    echo "    Then paste it here when ready."
    echo ""
    read -rp "    Paste your Claude API token: " CLAUDE_TOKEN
    if [ -n "$CLAUDE_TOKEN" ]; then
      mkdir -p "$HOME/.config/gabayai"
      echo "$CLAUDE_TOKEN" > "$HOME/.config/gabayai/api-key"
      chmod 600 "$HOME/.config/gabayai/api-key"
      echo "    Token saved. /gabayai-core:setup will use it when creating .env"
    else
      echo "    No token entered — you can set ANTHROPIC_API_KEY later during setup."
    fi
  else
    echo "    [skip] Claude Code not installed — skipping authentication"
  fi
  set_step 15
fi

# ── 16. GabayAI bootstrap ─────────────────────────────────────────────────
if ! step_done 16; then
  if command -v claude &>/dev/null; then
    echo "==> [16/$TOTAL_STEPS] Installing GabayAI plugins..."
    claude plugin marketplace add obra/superpowers
    claude plugin install superpowers@superpowers --scope user
    claude plugin marketplace add ChabadLabs/GabayMarketplace
    claude plugin install gabayai-core@gabay-marketplace --scope user
  else
    echo "    [skip] Claude Code not installed — skipping GabayAI plugins"
  fi
  set_step 16
fi

# ── 17. Create code directory ───────────────────────────────────────────────
if ! step_done 17; then
  echo "==> [17/$TOTAL_STEPS] Creating ~/code..."
  mkdir -p "$HOME/code"
  set_step 17
fi

# ═══════════════════════════════════════════════════════════════════════════
# DONE — clean up
# ═══════════════════════════════════════════════════════════════════════════
remove_resume_hook
rm -f "$SCRIPT_PATH"

echo ""
echo "  Your server is ready! Now open Claude Code and run:"
echo ""
echo "    /gabayai-core:setup"
echo ""
echo "  This will set up your personal Shlichus AI assistant."
echo ""
echo "  (You may want to reboot first: sudo reboot)"

read -rp "Reboot now? [y/N] " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  sudo reboot
fi
