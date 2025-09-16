#!/bin/bash
set -euo pipefail

# =======================
#  Color & formatting 🎨
# =======================
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && \
   [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  RESET=$'\e[0m'
  BOLD=$'\e[1m'
  DIM=$'\e[2m'
  RED=$'\e[31m'
  GREEN=$'\e[32m'
  YELLOW=$'\e[33m'
  BLUE=$'\e[34m'
  MAGENTA=$'\e[35m'
  CYAN=$'\e[36m'
else
  RESET=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
fi

info() { printf "%sℹ️  %s%s\n" "$CYAN" "$*" "$RESET"; }
ok()   { printf "%s✅ %s%s\n" "$GREEN" "$*" "$RESET"; }
warn() { printf "%s⚠️  %s%s\n" "$YELLOW" "$*" "$RESET"; }
err()  { printf "%s❌ %s%s\n" "$RED"   "$*" "$RESET"; }
title(){ printf "\n%s%s🔹 === %s === 🔹%s\n" "$BOLD" "$MAGENTA" "$*" "$RESET"; }

# GitHub raw installer link
INSTALL_ONE_LINER='bash -c "$(curl -fsSL https://raw.githubusercontent.com/hjongedijk/cloudinit-preinstall/main/cloudinit-preinstall.sh)"'

# URLs for bundles
FILEBROWSER_URL="https://raw.githubusercontent.com/hjongedijk/cloudinit-preinstall/main/packages/filebrowser.zip"
MONITOR_URL="https://raw.githubusercontent.com/hjongedijk/cloudinit-preinstall/main/packages/monitoring.zip"

press_enter() {
  echo
  read -rp "👉 Press ENTER to continue..." _ || true
}

get_eth0_ip() {
  ip -4 addr show dev eth0 2>/dev/null | \
    awk '/inet / {print $2}' | cut -d/ -f1 | head -n1
}

ensure_unzip_curl() {
  apt-get update
  apt-get install -y unzip zip curl || true
}

# ------------------------------
# Session helpers 👤
# ------------------------------
active_session_user() {
  local u
  u="$(logname 2>/dev/null || true)"
  if [ -z "$u" ]; then
    u="$(who am i 2>/dev/null | awk '{print $1}' | head -n1)"
  fi
  if [ -z "$u" ] && [ -n "${SUDO_USER-}" ]; then
    u="$SUDO_USER"
  fi
  echo "$u"
}

user_has_active_sessions() {
  local u="$1"
  if loginctl list-sessions --no-legend 2>/dev/null | \
     awk -v user="$u" '$3==user{found=1} END{exit !found}'; then
    return 0
  fi
  if who 2>/dev/null | \
     awk -v user="$u" '$1==user{found=1} END{exit !found}'; then
    return 0
  fi
  return 1
}

logout_current_session() {
  local TTY_PATH
  local TTY_BASENAME
  TTY_PATH="$(tty 2>/dev/null || true)"
  TTY_BASENAME="${TTY_PATH#/dev/}"

  if [ -n "$TTY_BASENAME" ] && [ "$TTY_BASENAME" != "$TTY_PATH" ]; then
    echo "👋 Logging out current session on TTY: ${TTY_BASENAME}"
    sleep 1
    pkill -KILL -t "$TTY_BASENAME" 2>/dev/null || true
  fi

  kill -TERM -$$ 2>/dev/null || exit 0
}

next_steps_and_exit() {
  local ip
  ip="$(get_eth0_ip)"
  [ -z "$ip" ] && ip="<your_server_ip>"

  cat <<EOF

${BOLD}${CYAN}=====================================================
🎯 NEXT STEPS
=====================================================${RESET}

${GREEN}1) Preferred:${RESET} open the ${BOLD}Proxmox Console (xterm.js)${RESET} 
   for easy copy/paste and log in as ${BOLD}root${RESET}.
   ${DIM}Proxmox UI → Select VM → Console (xterm.js) → login as root${RESET}

${BLUE}2) Alternative via SSH:${RESET}
   ${BOLD}ssh root@${ip}${RESET}

${YELLOW}3) Log out / terminate your current non-root session${RESET}
   (otherwise deletion/changes cannot complete cleanly).

${MAGENTA}4) Re-run the installer:${RESET}
   ${BOLD}${INSTALL_ONE_LINER}${RESET}

${CYAN}5) Choose option 1 (Run ALL) or proceed step-by-step.${RESET}

=====================================================

EOF

  read -rp "❓ Do you want me to log out this session now? (y/yes to confirm) > " LOGOUT_ANS
  case "${LOGOUT_ANS,,}" in
    y|yes)
      echo "👋 Logging out..."
      sleep 2
      logout_current_session
      ;;
    *)
      echo "⏸️  Not logging out. Close this session manually."
      ;;
  esac

  exit 0
}

# ------------------------------
# EARLY PATH: Not root 🧯
# ------------------------------
if [ "$(id -u)" -ne 0 ]; then
  warn "Running as non-root. Minimal setup: set root password + SSH config."
  echo "After that, log in as root and re-run the full installer."

  read -srp "🔑 Enter new root password: " PW1; echo
  read -srp "🔑 Re-enter new root password: " PW2; echo
  if [ -z "$PW1" ] || [ "$PW1" != "$PW2" ]; then
    err "Passwords do not match. Aborting."
    exit 1
  fi

  echo "root:${PW1}" | sudo chpasswd
  sudo passwd -u root 2>/dev/null || true
  ok "Root password set."

  SSH_FILE="/etc/ssh/sshd_config"
  sudo sed -i 's/^[[:space:]]*PermitRootLogin.*/#&/' "$SSH_FILE" || true
  sudo sed -i 's/^[[:space:]]*PasswordAuthentication.*/#&/' "$SSH_FILE" || true
  echo "PermitRootLogin yes" | sudo tee -a "$SSH_FILE" >/dev/null
  echo "PasswordAuthentication yes" | sudo tee -a "$SSH_FILE" >/dev/null
  sudo systemctl restart ssh || sudo systemctl restart sshd || true
  ok "SSH configured."

  next_steps_and_exit
fi

# ------------------------------
# State for summary 🧾
# ------------------------------
USER_DELETE_RESULT="skipped"
USER_DELETED_FLAG=0
DOCKER_ACCESS_USERNAME=""
DOCKER_ACCESS_MODE=""

# ------------------------------
# Steps 🧰
# ------------------------------
step_update_upgrade() {
  title "[2] Update & Upgrade System"
  apt-get update
  apt-get -y upgrade
  ok "System updated."
}

step_install_base_packages() {
  title "[3] Install base packages"
  apt-get install -y sudo curl wget git unzip zip tar htop net-tools \
                     build-essential tmux screen jq tree fail2ban
  ok "Base packages installed."
}

step_set_root_password() {
  title "[4] Set root password"
  read -srp "🔑 Enter new root password: " PW1; echo
  read -srp "🔑 Re-enter new root password: " PW2; echo

  if [ -z "$PW1" ] || [ "$PW1" != "$PW2" ]; then
    warn "Passwords empty or do not match. Skipping."
    return
  fi

  echo "root:${PW1}" | chpasswd
  passwd -u root 2>/dev/null || true
  ok "Root password set."
}

step_ssh_config() {
  title "[5] Configure SSH"
  SSH_FILE="/etc/ssh/sshd_config"

  sed -i 's/^[[:space:]]*PermitRootLogin.*/#&/' "$SSH_FILE" || true
  sed -i 's/^[[:space:]]*PasswordAuthentication.*/#&/' "$SSH_FILE" || true

  {
    echo "PermitRootLogin yes"
    echo "PasswordAuthentication yes"
  } >> "$SSH_FILE"

  systemctl restart ssh || systemctl restart sshd || true
  ok "SSH configured (PermitRootLogin yes, PasswordAuthentication yes)."
}

delete_user_silent() {
  local USER_TO_DEL="$1"
  local ACTIVE_U
  ACTIVE_U="$(active_session_user)"

  if [ "$USER_TO_DEL" = "root" ] || [ -z "$USER_TO_DEL" ]; then
    return 1
  fi

  if ! id "$USER_TO_DEL" >/dev/null 2>&1; then
    return 1
  fi

  if [ "$USER_TO_DEL" = "$ACTIVE_U" ] && user_has_active_sessions "$USER_TO_DEL"; then
    warn "The user '$USER_TO_DEL' is the active session user."
    next_steps_and_exit
  fi

  if userdel -r "$USER_TO_DEL"; then
    ok "User '$USER_TO_DEL' deleted."
    USER_DELETED_FLAG=1
    return 0
  else
    err "Failed to delete '$USER_TO_DEL'."
    return 1
  fi
}

step_delete_user_interactive() {
  title "[6] Remove a user"
  read -rp "🗑️  Delete a user now? (y/yes to confirm): " ans
  case "${ans,,}" in
    y|yes)
      read -rp "👤 Username: " u
      if [ -z "$u" ]; then
        USER_DELETE_RESULT="skipped"
        return
      fi
      if delete_user_silent "$u"; then
        USER_DELETE_RESULT="deleted $u"
      else
        USER_DELETE_RESULT="failed ($u)"
      fi
      ;;
    *)
      USER_DELETE_RESULT="skipped"
      ;;
  esac
}

step_timezone() {
  title "[7] Set Timezone to Europe/Amsterdam"
  timedatectl set-timezone Europe/Amsterdam
  ok "Timezone set."
}

step_unzip_qga_getty() {
  title "[8] Install Zip/Unzip + QEMU Guest Agent + enable getty@tty1"
  apt-get update
  apt-get install -y zip unzip qemu-guest-agent
  systemctl enable --now qemu-guest-agent
  systemctl enable --now getty@tty1.service
  ok "Installed and enabled: zip/unzip, qemu-guest-agent, getty@tty1."
  info "💡 You can now remove the serial port in Proxmox and set Display to Default (VNC console)."
}

step_python_tools() {
  title "[9] Install Python, pip, and dev tools"
  apt-get update
  apt-get install -y python3 python3-pip python3-venv build-essential git curl
  ok "Python and tools installed."
}

step_install_docker() {
  title "[10] Install Docker"
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ok "Docker installed."
}

step_configure_docker_tcp() {
  title "[11] Configure Docker daemon to listen on TCP 2375"
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "hosts": ["unix:///var/run/docker.sock", "tcp://0.0.0.0:2375"]
}
EOF
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/docker.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd
EOF
  systemctl daemon-reload
  systemctl enable --now docker
  systemctl restart docker
  ok "Docker configured and restarted."
  warn "tcp://0.0.0.0:2375 is INSECURE (no TLS). Use only on trusted networks."
}

step_set_docker_access() {
  title "[12] Set Docker access"
  if [ "$USER_DELETED_FLAG" -eq 1 ]; then
    chmod 666 /var/run/docker.sock || true
    DOCKER_ACCESS_MODE="chmod_only"
    ok "Docker socket permissions set to 666 (no user added to docker group due to prior deletion)."
  else
    read -rp "👤 Enter the username to grant Docker access (blank to skip): " DOCKER_USER
    if [ -n "${DOCKER_USER}" ]; then
      if id "${DOCKER_USER}" >/dev/null 2>&1; then
        usermod -aG docker "${DOCKER_USER}" || true
        DOCKER_ACCESS_USERNAME="${DOCKER_USER}"
        DOCKER_ACCESS_MODE="group+chmod"
        ok "User '${DOCKER_USER}' added to 'docker' group."
      else
        echo "User '${DOCKER_USER}' does not exist. Skipping group add."
        DOCKER_ACCESS_MODE="chmod_only"
      fi
    else
      DOCKER_ACCESS_MODE="chmod_only"
    fi
    chmod 666 /var/run/docker.sock || true
    ok "Docker socket permissions set to 666."
  fi
}

step_filebrowser_bundle() {
  title "[13] Install Filebrowser bundle"
  ensure_unzip_curl
  mkdir -p /opt/filebrowser
  if curl -fL "$FILEBROWSER_URL" -o /opt/filebrowser/filebrowser.zip; then
    (
      cd /opt/filebrowser
      unzip -o filebrowser.zip
      rm -f filebrowser.zip
      docker compose up -d
    )
    ok "Filebrowser downloaded, extracted, and started."
  else
    warn "Failed to download Filebrowser bundle from: $FILEBROWSER_URL"
  fi
}

step_monitoring_bundle() {
  title "[14] Install Monitoring bundle"
  ensure_unzip_curl
  mkdir -p /opt/monitoring
  if curl -fL "$MONITOR_URL" -o /opt/monitoring/monitoring.zip; then
    (
      cd /opt/monitoring
      unzip -o monitoring.zip
      rm -f monitoring.zip
      docker compose up -d
    )
    ok "Monitoring downloaded, extracted, and started."
  else
    warn "Failed to download Monitoring bundle from: $MONITOR_URL"
  fi
}

step_cloudinit_and_apt_clean() {
  title "[15] Cloud-init cleanup & apt clean"
  cloud-init clean --logs || true
  rm -rf /var/lib/cloud/* || true
  rm -f /etc/cloud/cloud.cfg.d/90_dpkg.cfg || true
  truncate -s 0 /etc/machine-id || true
  rm -f /var/lib/dbus/machine-id || true
  rm -f /etc/netplan/50-cloud-init.yaml || true
  cloud-init clean || true
  apt-get -y autoremove --purge whiptail dialog || true
  apt-get -y autoremove || true
  apt-get clean || true
  rm -rf /var/lib/apt/lists/* || true
  ok "cloud-init cleaned and apt cache purged."
}

step_shutdown_prompt() {
  read -rp "⚡ Do you want to shutdown now? (y/yes): " SHUT_ANS
  case "${SHUT_ANS,,}" in
    y|yes)
      echo "📴 Shutting down in 5 seconds..."
      sleep 5
      shutdown -h now >/dev/null 2>&1 || true
      exit 0
      ;;
    *)
      echo "⏸️  Skipping shutdown. Returning to menu."
      ;;
  esac
}

# ------------------------------
# Run-all 🧩
# ------------------------------
run_all_steps() {
  step_update_upgrade
  step_install_base_packages
  step_set_root_password
  step_ssh_config
  step_delete_user_interactive
  step_timezone
  step_unzip_qga_getty
  step_python_tools
  step_install_docker
  step_configure_docker_tcp
  step_set_docker_access
  step_filebrowser_bundle
  step_monitoring_bundle
  step_cloudinit_and_apt_clean

  echo
  echo "====================================================="
  echo "📋 INSTALLATION OVERVIEW"
  echo "====================================================="
  echo "✅ System updated & upgraded"
  echo "✅ Base packages installed (sudo curl wget git unzip zip tar htop net-tools build-essential tmux screen jq tree fail2ban)"
  echo "✅ SSH configured (root login + password auth)"
  echo "ℹ️  User deletion step: $USER_DELETE_RESULT"
  echo "✅ Root password set/unlocked"
  echo "✅ Timezone set: Europe/Amsterdam"
  echo "✅ Installed: zip, unzip, qemu-guest-agent, getty@tty1"
  echo "✅ Installed: Python3, pip, dev tools"
  echo "✅ Installed: Docker CE + Compose plugins"
  echo "✅ Docker listening on: unix:///var/run/docker.sock, tcp://0.0.0.0:2375"
  if [ "${DOCKER_ACCESS_MODE:-}" = "group+chmod" ] && [ -n "${DOCKER_ACCESS_USERNAME:-}" ]; then
    echo "✅ Docker access: added '${DOCKER_ACCESS_USERNAME}' to 'docker' group + chmod 666"
  else
    echo "✅ Docker access: chmod 666 only"
  fi
  echo "✅ Filebrowser deployed in /opt/filebrowser"
  echo "✅ Monitoring deployed in /opt/monitoring"
  echo "✅ cloud-init cleaned, apt cache cleared"
  echo "====================================================="
  echo "⚠️  WARNING: Docker TCP (2375) is unsecured (no TLS)"
  echo "====================================================="
  echo "📝 Note: Add user, password, ip=dhcp in cloud-init Proxmox and regenerate the image."
  echo "💡 Tip: You can now remove the serial port in Proxmox and set Display to Default (VNC console)."
  echo

  step_shutdown_prompt
}

# ------------------------------
# Menu 📜
# ------------------------------
show_menu() {
  cat <<MENU

${BOLD}${CYAN}=== Debian Install Script ===${RESET}
${GREEN}1) 🚀 Run ALL steps (with summary; optional shutdown)${RESET}
${BLUE}2) 🔄 Update & Upgrade System${RESET}
${BLUE}3) 📦 Install base packages${RESET}
${BLUE}4) 🔐 Set root password${RESET}
${BLUE}5) 🔧 Configure SSH (root login + password auth)${RESET}
${BLUE}6) 🧹 Remove a user${RESET}
${BLUE}7) 🕰️  Set Timezone to Europe/Amsterdam${RESET}
${BLUE}8) 🧰 Install Zip/Unzip + QEMU Guest Agent (+ getty@tty1)${RESET}
${BLUE}9) 🐍 Install Python, pip & tools${RESET}
${BLUE}10) 🐳 Install Docker${RESET}
${BLUE}11) 🔌 Configure Docker Daemon (TCP 2375)${RESET}
${BLUE}12) 👥 Set Docker access${RESET}
${BLUE}13) 📁 Install Filebrowser bundle${RESET}
${BLUE}14) 📊 Install Monitoring bundle${RESET}
${BLUE}15) 🧽 Cloud-init cleanup & apt clean${RESET}
${RED}16) 📴 Shutdown system${RESET}
${RED}17) ❌ Exit${RESET}
${BOLD}${CYAN}=============================${RESET}
MENU
}

# ------------------------------
# Main loop 🔁
# ------------------------------
while true; do
  show_menu
  read -rp "👉 Choose an option [1-17]: " CHOICE
  case "$CHOICE" in
    1) run_all_steps ;;
    2) step_update_upgrade; press_enter ;;
    3) step_install_base_packages; press_enter ;;
    4) step_set_root_password; press_enter ;;
    5) step_ssh_config; press_enter ;;
    6) step_delete_user_interactive; press_enter ;;
    7) step_timezone; press_enter ;;
    8) step_unzip_qga_getty; press_enter ;;
    9) step_python_tools; press_enter ;;
    10) step_install_docker; press_enter ;;
    11) step_configure_docker_tcp; press_enter ;;
    12) step_set_docker_access; press_enter ;;
    13) step_filebrowser_bundle; press_enter ;;
    14) step_monitoring_bundle; press_enter ;;
    15) step_cloudinit_and_apt_clean; press_enter ;;
    16) step_shutdown_prompt ;;
    17) echo "👋 Bye!"; exit 0 ;;
    *)  err "Invalid choice." ;;
  esac
done
