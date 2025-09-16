#!/bin/bash
set -euo pipefail

# =======================
#  Color & formatting
# =======================
# Detect if stdout is a TTY and supports colors; otherwise disable colors
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  RESET=$'\e[0m'
  BOLD=$'\e[1m'
  DIM=$'\e[2m'
  RED=$'\e[31m'
  GREEN=$'\e[32m'
  YELLOW=$'\e[33m'
  CYAN=$'\e[36m'
else
  RESET=""
  BOLD=""
  DIM=""
  RED=""
  GREEN=""
  YELLOW=""
  CYAN=""
fi

info()    { printf "%s%s%s\n"   "$CYAN"  "$*" "$RESET"; }
ok()      { printf "%s✓ %s%s\n" "$GREEN" "$*" "$RESET"; }
warn()    { printf "%s⚠️  %s%s\n" "$YELLOW" "$*" "$RESET"; }
err()     { printf "%s❌ %s%s\n" "$RED"   "$*" "$RESET"; }
title()   { printf "\n%s=== %s ===%s\n" "$BOLD" "$*" "$RESET"; }

# --- Config: GitHub raw URL for re-run hint ---
INSTALL_ONE_LINER='bash -c "$(curl -fsSL https://raw.githubusercontent.com/hjongedijk/cloudinit-preinstall/main/cloudinit-preinstall.sh)"'

# --- URLs for bundles ---
FILEBROWSER_URL="https://raw.githubusercontent.com/hjongedijk/cloudinit-preinstall/main/packages/filebrowser.zip"
MONITOR_URL="https://raw.githubusercontent.com/hjongedijk/cloudinit-preinstall/main/packages/monitoring.zip"

press_enter() {
  echo
  read -rp "Press ENTER to continue..." _ || true
}

get_eth0_ip() {
  ip -4 addr show dev eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1
}

ensure_unzip_curl() {
  apt-get update
  apt-get install -y unzip zip curl || true
}

# ------------------------------
# Session helpers
# ------------------------------

active_session_user() {
  # Try to determine the real interactive user
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
  if loginctl list-sessions --no-legend 2>/dev/null | awk -v user="$u" '$3==user{found=1} END{exit !found}'; then
    return 0
  fi
  if who 2>/dev/null | awk -v user="$u" '$1==user{found=1} END{exit !found}'; then
    return 0
  fi
  return 1
}

logout_current_session() {
  # Attempt to terminate the current TTY session safely (only if user confirms)
  local TTY_PATH TTY_BASENAME
  TTY_PATH="$(tty 2>/dev/null || true)"
  TTY_BASENAME="${TTY_PATH#/dev/}"

  if [ -n "$TTY_BASENAME" ] && [ "$TTY_BASENAME" != "$TTY_PATH" ]; then
    echo "Logging out current session on TTY: ${TTY_BASENAME}"
    sleep 1
    pkill -KILL -t "$TTY_BASENAME" 2>/dev/null || true
  fi

  # Fallback: end current shell
  kill -TERM -$$ 2>/dev/null || exit 0
}

next_steps_and_exit() {
  local ip; ip="$(get_eth0_ip)"; [ -z "$ip" ] && ip="<your_server_ip>"
  cat <<EOF

=====================================================
${BOLD}NEXT STEPS${RESET}
-----------------------------------------------------
1) ${BOLD}Preferred:${RESET} open the ${BOLD}Proxmox Console (xterm.js)${RESET} for easy copy/paste and log in as ${BOLD}root${RESET}.

   ${DIM}Proxmox UI → Select VM → Console (xterm.js) → login as root${RESET}

   ${BOLD}Alternative via SSH:${RESET}
   ${BOLD}ssh root@${ip}${RESET}

2) ${YELLOW}Log out / terminate your current non-root session${RESET}
   (otherwise deletion/changes cannot complete cleanly).

   Do you want me to log out this session now? (y/yes to confirm)
EOF

  read -rp "> " LOGOUT_ANS
  case "${LOGOUT_ANS,,}" in
    y|yes)
      echo "Okay, logging out this session..."
      logout_current_session
      ;;
    *)
      echo "Okay, NOT logging out. You can close this session manually."
      ;;
  esac

  cat <<EOF

3) Re-run the installer:
   ${BOLD}${INSTALL_ONE_LINER}${RESET}

4) Choose ${BOLD}option 1 (Run ALL)${RESET} or proceed step-by-step.
=====================================================

EOF
  exit 0
}

# ------------------------------
# EARLY PATH: Not root -> only set root password + SSH, then exit
# ------------------------------
if [ "$(id -u)" -ne 0 ]; then
  warn "Running as non-root. Minimal setup: set root password + SSH config."
  echo "After that, log in as root and re-run the full installer."

  # --- Set root password (via sudo) ---
  printf "[3] Set root password (and unlock root)...\n"
  read -srp "Enter new root password: " PW1; echo
  read -srp "Re-enter new root password: " PW2; echo
  if [ -z "${PW1}" ] || [ "${PW1}" != "${PW2}" ]; then
    err "Passwords empty or do not match. Aborting."
    exit 1
  fi
  echo "root:${PW1}" | sudo chpasswd
  sudo passwd -u root 2>/dev/null || true
  ok "Root password set and root unlocked."

  # --- SSH config (via sudo) ---
  printf "[4] Configure SSH...\n"
  SSH_FILE="/etc/ssh/sshd_config"
  sudo sed -i 's/^[[:space:]]*PermitRootLogin[[:space:]].*/#&/' "$SSH_FILE" || true
  sudo sed -i 's/^[[:space:]]*PasswordAuthentication[[:space:]].*/#&/' "$SSH_FILE" || true
  echo "PermitRootLogin yes" | sudo tee -a "$SSH_FILE" >/dev/null
  echo "PasswordAuthentication yes" | sudo tee -a "$SSH_FILE" >/dev/null
  sudo systemctl restart ssh || sudo systemctl restart sshd || true
  ok "SSH configured."

  next_steps_and_exit
fi

# ------------------------------
# Full installer (running as root)
# ------------------------------

USER_DELETE_RESULT="skipped"
USER_DELETED_FLAG=0
DOCKER_ACCESS_USERNAME=""
DOCKER_ACCESS_MODE=""   # "chmod_only" or "group+chmod"

# ------------------------------
# Steps
# ------------------------------

step_update_upgrade() {
  title "🔄 [2] Update & Upgrade System"
  apt-get update
  apt-get -y upgrade
  ok "System updated."
}

step_install_base_packages() {
  title "📦 [3] Install base packages"
  apt-get install -y sudo curl wget git unzip zip tar htop net-tools build-essential tmux screen jq tree fail2ban
  ok "Base packages installed."
}

step_set_root_password() {
  title "🔐 [4] Set root password"
  read -srp "Enter new root password: " PW1; echo
  read -srp "Re-enter new root password: " PW2; echo
  if [ -z "${PW1}" ] || [ "${PW1}" != "${PW2}" ]; then
    warn "Passwords empty or do not match. Skipping."
    return
  fi
  echo "root:${PW1}" | chpasswd
  passwd -u root 2>/dev/null || true
  ok "Root password set."
}

step_ssh_config() {
  title "🔧 [5] Configure SSH"
  SSH_FILE="/etc/ssh/sshd_config"
  sed -i 's/^[[:space:]]*PermitRootLogin[[:space:]].*/#&/' "$SSH_FILE" || true
  sed -i 's/^[[:space:]]*PasswordAuthentication[[:space:]].*/#&/' "$SSH_FILE" || true
  {
    echo "PermitRootLogin yes"
    echo "PasswordAuthentication yes"
  } >> "$SSH_FILE"
  systemctl restart ssh || systemctl restart sshd || true
  ok "SSH configured."
}

delete_user_silent() {
  local USER_TO_DEL="$1"
  local ACTIVE_U; ACTIVE_U="$(active_session_user)"

  if [ "$USER_TO_DEL" = "root" ] || [ -z "$USER_TO_DEL" ]; then
    echo "Invalid target. Skipping."
    return 1
  fi
  if ! id "$USER_TO_DEL" >/dev/null 2>&1; then
    echo "User not found. Skipping."
    return 1
  fi

  # If target equals the active session user and sessions exist -> show NEXT STEPS (optional logout), then exit
  if [ "$USER_TO_DEL" = "$ACTIVE_U" ] && user_has_active_sessions "$USER_TO_DEL"; then
    warn "The user '$USER_TO_DEL' is the active session user."
    next_steps_and_exit
  fi

  # Proceed to delete (for other users or no active session)
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
  title "🧹 [6] Remove a user"
  read -rp "Delete a user now? [Y/n]: " ans
  case "${ans,,}" in
    n|no)
      USER_DELETE_RESULT="skipped"
      ;;
    *)
      read -rp "Enter username: " u
      echo "About to delete '${u}'. Confirm (y/yes):"
      read -rp "> " c
      if [[ "${c,,}" =~ ^(y|yes)$ ]]; then
        if delete_user_silent "$u"; then
          USER_DELETE_RESULT="deleted $u"
        else
          USER_DELETE_RESULT="failed ($u)"
        fi
      else
        USER_DELETE_RESULT="skipped"
      fi
      ;;
  esac
}

step_timezone() {
  title "🕰️  [7] Set Timezone to Europe/Amsterdam"
  timedatectl set-timezone Europe/Amsterdam
  ok "Timezone set."
}

step_unzip_qga_getty() {
  title "🧰 [8] Install Zip/Unzip + QEMU Guest Agent + enable getty@tty1"
  apt-get update
  apt-get install -y zip unzip qemu-guest-agent
  systemctl enable --now qemu-guest-agent
  systemctl enable --now getty@tty1.service
  ok "Installed and enabled: zip/unzip, qemu-guest-agent, getty@tty1."
}

step_python_tools() {
  title "🐍 [9] Install Python, pip, and dev tools"
  apt-get update
  apt-get install -y python3 python3-pip python3-venv build-essential git curl
  ok "Python and tools installed."
}

step_install_docker() {
  title "🐳 [10] Install Docker"
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ok "Docker installed."
}

step_configure_docker_tcp() {
  title "🔌 [11] Configure Docker daemon to listen on TCP 2375"
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
  title "👥 [12] Set Docker access"
  if [ "${USER_DELETED_FLAG}" -eq 1 ]; then
    chmod 666 /var/run/docker.sock || true
    DOCKER_ACCESS_MODE="chmod_only"
    ok "Docker socket permissions set to 666 (no user added to docker group due to prior deletion)."
  else
    read -rp "Enter the username to grant Docker access (leave blank to skip): " DOCKER_USER
    if [ -n "${DOCKER_USER}" ]; then
      if id "${DOCKER_USER}" >/dev/null 2>&1; then
        usermod -aG docker "${DOCKER_USER}" || true
        DOCKER_ACCESS_USERNAME="${DOCKER_USER}"
        DOCKER_ACCESS_MODE="group+chmod"
        ok "User '${DOCKER_USER}' added to 'docker' group (re-login required)."
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
  title "📁 [13] Install Filebrowser bundle"
  ensure_unzip_curl
  mkdir -p /opt/filebrowser
  curl -fL "$FILEBROWSER_URL" -o /opt/filebrowser/filebrowser.zip
  (cd /opt/filebrowser && unzip -o filebrowser.zip && rm -f filebrowser.zip && docker compose up -d)
  ok "Filebrowser downloaded, extracted, and started."
}

step_monitoring_bundle() {
  title "📊 [14] Install Monitoring bundle"
  ensure_unzip_curl
  mkdir -p /opt/monitoring
  curl -fL "$MONITOR_URL" -o /opt/monitoring/monitoring.zip
  (cd /opt/monitoring && unzip -o monitoring.zip && rm -f monitoring.zip && docker compose up -d)
  ok "Monitoring downloaded, extracted, and started."
}

step_cloudinit_and_apt_clean() {
  title "🧽 [15] Cloud-init cleanup & apt clean"
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

# ------------------------------
# Run-all
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

  # Fancy colored overview
  printf "\n%s=====================================================%s\n" "$BOLD" "$RESET"
  printf "%s🚀 INSTALLATION OVERVIEW%s\n" "$BOLD" "$RESET"
  printf "%s-----------------------------------------------------%s\n" "$BOLD" "$RESET"
  printf "%s✔%s System updated & upgraded\n" "$GREEN" "$RESET"
  printf "%s✔%s Base packages installed (sudo curl wget git unzip zip tar htop net-tools build-essential tmux screen jq tree fail2ban)\n" "$GREEN" "$RESET"
  printf "%s✔%s SSH configured: root login + password auth enabled\n" "$GREEN" "$RESET"
  printf "%s✔%s User deletion step: %s%s%s\n" "$GREEN" "$RESET" "$BOLD" "$USER_DELETE_RESULT" "$RESET"
  printf "%s✔%s Root password set/unlocked\n" "$GREEN" "$RESET"
  printf "%s✔%s Timezone set: Europe/Amsterdam\n" "$GREEN" "$RESET"
  printf "%s✔%s Installed: zip, unzip, qemu-guest-agent, getty@tty1\n" "$GREEN" "$RESET"
  printf "%s✔%s Installed: Python3, pip, dev tools\n" "$GREEN" "$RESET"
  printf "%s✔%s Installed: Docker CE + Compose plugins\n" "$GREEN" "$RESET"
  printf "%s✔%s Docker listening on: unix:///var/run/docker.sock, tcp://0.0.0.0:2375\n" "$GREEN" "$RESET"
  if [ "${DOCKER_ACCESS_MODE:-}" = "group+chmod" ] && [ -n "${DOCKER_ACCESS_USERNAME:-}" ]; then
    printf "%s✔%s Docker access: added '%s%s%s' to 'docker' group + chmod 666 on socket\n" "$GREEN" "$RESET" "$BOLD" "$DOCKER_ACCESS_USERNAME" "$RESET"
  else
    printf "%s✔%s Docker access: chmod 666 on socket (no user group add)\n" "$GREEN" "$RESET"
  fi
  printf "%s✔%s Filebrowser deployed (/opt/filebrowser)\n" "$GREEN" "$RESET"
  printf "%s✔%s Monitoring deployed (/opt/monitoring)\n" "$GREEN" "$RESET"
  printf "%s✔%s cloud-init cleaned, apt cache cleared\n" "$GREEN" "$RESET"
  printf "%s=====================================================%s\n" "$BOLD" "$RESET"
  printf "%s⚠️  WARNING:%s Docker TCP (2375) is unsecured (no TLS)\n" "$YELLOW" "$RESET"
  printf "%s=====================================================%s\n\n" "$BOLD" "$RESET"

  printf "%sNote:%s Do not forget to %sadd user, password, ip=dhcp in cloud-init Proxmox and regenerate the image.%s\n\n" "$BOLD" "$RESET" "$BOLD" "$RESET"

  info "System will now power off..."
  sleep 5
  shutdown -h now
}

# ------------------------------
# Menu
# ------------------------------
show_menu() {
  cat <<MENU

=== Debian Install Script ===
1) Run ALL steps (recommended; powers off at end)
2) Update & Upgrade System
3) Install base packages
4) Set root password (and unlock root)
5) Configure SSH (root login + password auth)
6) Remove a user (default YES; if target is your active session -> NEXT STEPS prompt & optional logout, then exit)
7) Set Timezone to Europe/Amsterdam
8) Install Zip/Unzip + QEMU Guest Agent (+ enable getty@tty1)
9) Install Python, pip & tools
10) Install Docker
11) Configure Docker Daemon (TCP 2375)
12) Set Docker access (add user to 'docker' or chmod-only)
13) Install Filebrowser bundle (docker compose)
14) Install Monitoring bundle (docker compose)
15) Cloud-init cleanup & apt clean
16) Exit
=============================
MENU
}

while true; do
  show_menu
  read -rp "Choose an option [1-16]: " CHOICE
  case "${CHOICE}" in
    1)  run_all_steps ;;
    2)  step_update_upgrade; press_enter ;;
    3)  step_install_base_packages; press_enter ;;
    4)  step_set_root_password; press_enter ;;
    5)  step_ssh_config; press_enter ;;
    6)  step_delete_user_interactive; press_enter ;;
    7)  step_timezone; press_enter ;;
    8)  step_unzip_qga_getty; press_enter ;;
    9)  step_python_tools; press_enter ;;
    10) step_install_docker; press_enter ;;
    11) step_configure_docker_tcp; press_enter ;;
    12) step_set_docker_access; press_enter ;;
    13) step_filebrowser_bundle; press_enter ;;
    14) step_monitoring_bundle; press_enter ;;
    15) step_cloudinit_and_apt_clean; press_enter ;;
    16) echo "Bye!"; exit 0 ;;
    *)  echo "Invalid choice." ;;
  esac
done
