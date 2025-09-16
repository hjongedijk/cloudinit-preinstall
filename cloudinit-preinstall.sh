#!/bin/bash
set -euo pipefail

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
  if ! command -v unzip >/dev/null 2>&1; then
    apt-get update
    apt-get install -y unzip zip
  fi
  if ! command -v curl >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl
  fi
}

# ------------------------------
# EARLY PATH: Not root -> only set root password + SSH, then exit with instructions
# ------------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "⚠️  Running as non-root. Performing minimal setup: set root password + SSH config."
  echo "    After that, log in as root and re-run the full installer."

  # --- Set root password (via sudo) ---
  read -srp "Enter new root password: " PW1; echo
  read -srp "Re-enter new root password: " PW2; echo
  if [ -z "${PW1}" ] || [ "${PW1}" != "${PW2}" ]; then
    echo "❌ Passwords empty or do not match. Aborting."
    exit 1
  fi
  if ! echo "root:${PW1}" | sudo chpasswd; then
    echo "❌ Failed to set root password (sudo chpasswd)."
    exit 1
  fi
  sudo passwd -u root 2>/dev/null || true
  echo "✓ Root password set and root unlocked."

  # --- SSH config (via sudo) ---
  SSH_FILE="/etc/ssh/sshd_config"
  sudo sed -i 's/^[[:space:]]*PermitRootLogin[[:space:]].*/#&/' "$SSH_FILE" || true
  sudo sed -i 's/^[[:space:]]*PasswordAuthentication[[:space:]].*/#&/' "$SSH_FILE" || true
  echo "PermitRootLogin yes" | sudo tee -a "$SSH_FILE" >/dev/null
  echo "PasswordAuthentication yes" | sudo tee -a "$SSH_FILE" >/dev/null
  sudo systemctl restart ssh || sudo systemctl restart sshd || true
  echo "✓ SSH configured: root login + password auth enabled."

  IP="$(get_eth0_ip)"
  if [ -z "$IP" ]; then
    IP="<your_server_ip>"
  fi

  cat <<EOF

=====================================================
NEXT STEPS
-----------------------------------------------------
1) Log out and log in as root using the password you just set:
   ssh root@${IP}

2) Re-run the installer:
   ${INSTALL_ONE_LINER}

3) Choose option 1 (Run ALL) or proceed step-by-step.
=====================================================
EOF
  exit 0
fi

# ------------------------------
# Full installer (running as root)
# ------------------------------

# Track outcomes for the overview
USER_DELETE_RESULT="skipped"
USER_DELETED_FLAG=0
DOCKER_ACCESS_USERNAME=""
DOCKER_ACCESS_MODE=""   # "chmod_only" or "group+chmod"

# ------------------------------
# Steps
# ------------------------------

step_update_upgrade() {
  echo "[2] Update & Upgrade System..."
  apt-get update
  apt-get -y upgrade
  echo "✓ System updated."
}

step_set_root_password() {
  echo "[3] Set root password (and unlock root)..."
  read -srp "Enter new root password: " PW1; echo
  read -srp "Re-enter new root password: " PW2; echo
  if [ -z "${PW1}" ] || [ "${PW1}" != "${PW2}" ]; then
    echo "⚠️  Passwords empty or do not match. Skipping."
    return 0
  fi
  echo "root:${PW1}" | chpasswd
  passwd -u root 2>/dev/null || true
  echo "✓ Root password set and root unlocked."
}

step_ssh_config() {
  echo "[4] Configure SSH (PermitRootLogin yes, PasswordAuthentication yes)..."
  SSH_FILE="/etc/ssh/sshd_config"
  sed -i 's/^[[:space:]]*PermitRootLogin[[:space:]].*/#&/' "$SSH_FILE" || true
  sed -i 's/^[[:space:]]*PasswordAuthentication[[:space:]].*/#&/' "$SSH_FILE" || true
  {
    echo "PermitRootLogin yes"
    echo "PasswordAuthentication yes"
  } >> "$SSH_FILE"
  systemctl restart ssh || systemctl restart sshd || true
  echo "✓ SSH configured and restarted."
}

# --- User deletion (after SSH config) ---

delete_user_silent() {
  local USER_TO_DEL="$1"
  local USER_HOME

  if [ -z "$USER_TO_DEL" ] || [ "$USER_TO_DEL" = "root" ]; then
    echo "Skipping invalid username for deletion."
    return 0
  fi
  if ! id "$USER_TO_DEL" >/dev/null 2>&1; then
    echo "User '$USER_TO_DEL' does not exist. Skipping."
    return 0
  fi

  USER_HOME="$(getent passwd "$USER_TO_DEL" | cut -d: -f6)"
  echo "Deleting user '$USER_TO_DEL' (HOME: ${USER_HOME:-N/A})..."
  loginctl terminate-user "$USER_TO_DEL" 2>/dev/null || true
  pkill -u "$USER_TO_DEL" 2>/dev/null || true
  if userdel -r "$USER_TO_DEL"; then
    crontab -r -u "$USER_TO_DEL" 2>/dev/null || true
    if [ -n "${USER_HOME:-}" ] && [ -d "$USER_HOME" ]; then
      rm -rf --one-file-system "$USER_HOME"
    fi
    rm -f "/var/mail/$USER_TO_DEL" 2>/dev/null || true
    rm -rf "/var/spool/cron/crontabs/$USER_TO_DEL" 2>/dev/null || true
    echo "✓ User '$USER_TO_DEL' removed and leftovers cleaned."
    return 0
  else
    echo "❌ Failed to delete '$USER_TO_DEL'."
    return 1
  fi
}

step_delete_user_interactive() {
  echo "[5] Remove a user (default: YES)"
  read -rp "Do you want to delete a user now? [Y/n]: " DEL_ANS
  case "${DEL_ANS,,}" in
    n|no)
      echo "Skipping user deletion."
      USER_DELETE_RESULT="skipped"
      USER_DELETED_FLAG=0
      ;;
    *)
      read -rp "Enter the username to delete: " USER_TO_DEL
      if [ -z "${USER_TO_DEL}" ]; then
        echo "No username given. Skipping user deletion."
        USER_DELETE_RESULT="skipped"
        USER_DELETED_FLAG=0
        return 0
      fi
      echo "About to delete '${USER_TO_DEL}'. Confirm (y/yes):"
      read -rp "> " CONFIRM
      case "${CONFIRM,,}" in
        y|yes)
          if delete_user_silent "$USER_TO_DEL"; then
            USER_DELETE_RESULT="executed (deleted: ${USER_TO_DEL})"
            USER_DELETED_FLAG=1
          else
            USER_DELETE_RESULT="failed"
            USER_DELETED_FLAG=0
          fi
          ;;
        *)
          echo "User deletion cancelled."
          USER_DELETE_RESULT="skipped"
          USER_DELETED_FLAG=0
          ;;
      esac
      ;;
  esac
}

step_timezone() {
  echo "[6] Set Timezone to Europe/Amsterdam..."
  timedatectl set-timezone Europe/Amsterdam
  echo "✓ Timezone set."
}

step_unzip_qga_getty() {
  echo "[7] Install Zip/Unzip + QEMU Guest Agent and enable getty@tty1..."
  apt-get update
  apt-get install -y zip unzip qemu-guest-agent
  systemctl enable --now qemu-guest-agent
  systemctl enable --now getty@tty1.service
  echo "✓ Installed and enabled: zip/unzip, qemu-guest-agent, getty@tty1."
}

step_python_tools() {
  echo "[8] Install Python, pip, and dev tools..."
  apt-get update
  apt-get install -y python3 python3-pip python3-venv build-essential git curl
  echo "✓ Python and tools installed."
}

step_install_docker() {
  echo "[9] Install Docker..."
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  echo "✓ Docker installed."
}

step_configure_docker_tcp() {
  echo "[10] Configure Docker daemon to listen on TCP 2375..."
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
  echo "✓ Docker configured and restarted."
  echo "⚠️ WARNING: tcp://0.0.0.0:2375 is INSECURE (no TLS)."
}

# Post-docker access:
# - If a user WAS deleted earlier → ONLY chmod 666 /var/run/docker.sock
# - Else → ask for a username, add to docker group, then chmod 666
step_set_docker_access() {
  echo "[11] Set Docker access..."
  if [ "${USER_DELETED_FLAG}" -eq 1 ]; then
    chmod 666 /var/run/docker.sock || true
    DOCKER_ACCESS_MODE="chmod_only"
    echo "✓ Docker socket permissions set to 666 (no user added to docker group due to prior deletion)."
  else
    read -rp "Enter the username to grant Docker access (leave blank to skip): " DOCKER_USER
    if [ -n "${DOCKER_USER}" ]; then
      if id "${DOCKER_USER}" >/dev/null 2>&1; then
        usermod -aG docker "${DOCKER_USER}" || true
        DOCKER_ACCESS_USERNAME="${DOCKER_USER}"
        DOCKER_ACCESS_MODE="group+chmod"
        echo "✓ User '${DOCKER_USER}' added to 'docker' group (re-login required)."
      else
        echo "User '${DOCKER_USER}' does not exist. Skipping group add."
        DOCKER_ACCESS_MODE="chmod_only"
      fi
    else
      DOCKER_ACCESS_MODE="chmod_only"
    fi
    chmod 666 /var/run/docker.sock || true
    echo "✓ Docker socket permissions set to 666."
  fi
}

step_filebrowser_bundle() {
  echo "[12] Install Filebrowser bundle..."
  ensure_unzip_curl
  mkdir -p /opt/filebrowser
  curl -fL "$FILEBROWSER_URL" -o /opt/filebrowser/filebrowser.zip
  (cd /opt/filebrowser && unzip -o filebrowser.zip && rm -f filebrowser.zip && docker compose up -d)
  echo "✓ Filebrowser downloaded, extracted, and started."
}

step_monitoring_bundle() {
  echo "[13] Install Monitoring bundle..."
  ensure_unzip_curl
  mkdir -p /opt/monitoring
  curl -fL "$MONITOR_URL" -o /opt/monitoring/monitoring.zip
  (cd /opt/monitoring && unzip -o monitoring.zip && rm -f monitoring.zip && docker compose up -d)
  echo "✓ Monitoring downloaded, extracted, and started."
}

step_cloudinit_and_apt_clean() {
  echo "[14] Cloud-init cleanup & apt clean..."
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
  echo "✓ cloud-init cleaned and apt cache purged."
}

# ------------------------------
# Run-all
# ------------------------------
run_all_steps() {
  step_update_upgrade
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
  echo "✅ INSTALLATION OVERVIEW"
  echo "-----------------------------------------------------"
  echo "✔ System updated & upgraded"
  echo "✔ SSH configured: root login + password auth enabled"
  echo "✔ User deletion step: ${USER_DELETE_RESULT}"
  echo "✔ Root password set/unlocked"
  echo "✔ Timezone set: Europe/Amsterdam"
  echo "✔ Installed: zip, unzip, qemu-guest-agent, getty@tty1"
  echo "✔ Installed: Python3, pip, dev tools"
  echo "✔ Installed: Docker CE + Compose plugins"
  echo "✔ Docker listening on: unix:///var/run/docker.sock, tcp://0.0.0.0:2375"
  if [ "$DOCKER_ACCESS_MODE" = "group+chmod" ] && [ -n "$DOCKER_ACCESS_USERNAME" ]; then
    echo "✔ Docker access: added '${DOCKER_ACCESS_USERNAME}' to 'docker' group + chmod 666 on socket"
  else
    echo "✔ Docker access: chmod 666 on socket (no user group add)"
  fi
  echo "✔ Filebrowser deployed (/opt/filebrowser)"
  echo "✔ Monitoring deployed (/opt/monitoring)"
  echo "✔ cloud-init cleaned, apt cache cleared"
  echo "====================================================="
  echo "⚠️  WARNING: Docker TCP (2375) is unsecured (no TLS)"
  echo "====================================================="
  echo
  echo "Do not forget to add user, password, ip=dhcp in cloud-init Proxmox and regenerate the image."
  echo
  echo "System will now power off..."
  sleep 5
  shutdown -h now
}

# ------------------------------
# Menu
# ------------------------------
show_menu() {
  cat <<MENU

================= Debian Install Script =================
1) Run ALL steps (recommended; powers off at end)
2) Update & Upgrade System
3) Set root password (and unlock root)
4) Configure SSH (root login + password auth)
5) Remove a user (prompt, default YES)
6) Set Timezone to Europe/Amsterdam
7) Install Zip/Unzip + QEMU Guest Agent (+ enable getty@tty1)
8) Install Python, pip & tools
9) Install Docker
10) Configure Docker Daemon (TCP 2375)
11) Set Docker access (add user to 'docker' or chmod-only)
12) Install Filebrowser bundle (docker compose)
13) Install Monitoring bundle (docker compose)
14) Cloud-init cleanup & apt clean
15) Exit
=========================================================
MENU
}

while true; do
  show_menu
  read -rp "Choose an option [1-15]: " CHOICE
  case "${CHOICE}" in
    1)  run_all_steps ;;
    2)  step_update_upgrade; press_enter ;;
    3)  step_set_root_password; press_enter ;;
    4)  step_ssh_config; press_enter ;;
    5)  step_delete_user_interactive; press_enter ;;
    6)  step_timezone; press_enter ;;
    7)  step_unzip_qga_getty; press_enter ;;
    8)  step_python_tools; press_enter ;;
    9)  step_install_docker; press_enter ;;
    10) step_configure_docker_tcp; press_enter ;;
    11) step_set_docker_access; press_enter ;;
    12) step_filebrowser_bundle; press_enter ;;
    13) step_monitoring_bundle; press_enter ;;
    14) step_cloudinit_and_apt_clean; press_enter ;;
    15) echo "Bye!"; exit 0 ;;
    *)  echo "Invalid choice." ;;
  esac
done
