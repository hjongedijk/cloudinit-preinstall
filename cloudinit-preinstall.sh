#!/bin/bash
set -euo pipefail

# --- Ensure script is run as root ---
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ This script must be run as root."
  echo "➡️  Please run:"
  echo "    sudo su"
  echo "    bash $0"
  exit 1
fi

# --- URLs for bundles ---
FILEBROWSER_URL="https://raw.githubusercontent.com/hjongedijk/cloudinit-preinstall/main/packages/filebrowser.zip"
MONITOR_URL="https://raw.githubusercontent.com/hjongedijk/cloudinit-preinstall/main/packages/monitoring.zip"

press_enter() {
  echo
  read -rp "Press ENTER to continue..." _ || true
}

# ------------------------------
# Functions (steps)
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
  # Comment out any existing conflicting lines to avoid duplicates
  sed -i 's/^[[:space:]]*PermitRootLogin[[:space:]].*/#&/' "$SSH_FILE" || true
  sed -i 's/^[[:space:]]*PasswordAuthentication[[:space:]].*/#&/' "$SSH_FILE" || true
  # Append desired settings
  {
    echo "PermitRootLogin yes"
    echo "PasswordAuthentication yes"
  } >> "$SSH_FILE"
  systemctl restart ssh
  echo "✓ SSH configured and restarted."
}

step_timezone() {
  echo "[5] Set Timezone to Europe/Amsterdam..."
  timedatectl set-timezone Europe/Amsterdam
  echo "✓ Timezone set."
}

step_unzip_qga_getty() {
  echo "[6] Install Zip/Unzip + QEMU Guest Agent and enable getty@tty1..."
  apt-get update
  apt-get install -y zip unzip qemu-guest-agent
  systemctl enable --now qemu-guest-agent
  systemctl enable --now getty@tty1.service
  echo "✓ Installed and enabled: zip/unzip, qemu-guest-agent, getty@tty1."
}

step_python_tools() {
  echo "[7] Install Python, pip, and dev tools..."
  apt-get update
  apt-get install -y python3 python3-pip python3-venv build-essential git curl
  echo "✓ Python and tools installed."
}

step_install_docker() {
  echo "[8] Install Docker..."
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
  echo "[9] Configure Docker daemon to listen on TCP 2375..."
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
  echo "⚠️ WARNING: tcp://0.0.0.0:2375 is INSECURE (no TLS). Use only on trusted networks."
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

step_filebrowser_bundle() {
  echo "[10] Install Filebrowser bundle..."
  ensure_unzip_curl
  mkdir -p /opt/filebrowser
  TARGET="/opt/filebrowser/filebrowser.zip"
  if ! curl -fL "$FILEBROWSER_URL" -o "$TARGET"; then
    echo "❌ Download failed from: $FILEBROWSER_URL"
    return 0
  fi
  (cd /opt/filebrowser && unzip -o filebrowser.zip && rm -f filebrowser.zip && docker compose up -d)
  echo "✓ Filebrowser downloaded, extracted, and started."
}

step_monitoring_bundle() {
  echo "[11] Install Monitoring bundle..."
  ensure_unzip_curl
  mkdir -p /opt/monitoring
  TARGET="/opt/monitoring/monitoring.zip"
  if ! curl -fL "$MONITOR_URL" -o "$TARGET"; then
    echo "❌ Download failed from: $MONITOR_URL"
    return 0
  fi
  (cd /opt/monitoring && unzip -o monitoring.zip && rm -f monitoring.zip && docker compose up -d)
  echo "✓ Monitoring downloaded, extracted, and started."
}

delete_user_silent() {
  # $1 = username to delete (no interactive confirmations here)
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
  else
    echo "❌ Failed to delete '$USER_TO_DEL'. Check running processes or mounts."
  fi
}

step_delete_user_interactive() {
  echo "[12] Remove a user (optional)"
  read -rp "Do you want to delete a user now? (y/N): " DEL_ANS
  case "${DEL_ANS,,}" in
    y|yes)
      read -rp "Enter the username to delete: " USER_TO_DEL
      if [ -z "${USER_TO_DEL}" ]; then
        echo "No username given. Skipping user deletion."
        return 1
      fi
      echo "About to delete '${USER_TO_DEL}'. Type YES to confirm:"
      read -rp "> " CONFIRM
      if [ "${CONFIRM}" = "YES" ]; then
        delete_user_silent "$USER_TO_DEL"
        return 0
      else
        echo "User deletion cancelled."
        return 1
      fi
      ;;
    *)
      echo "Skipping user deletion."
      return 1
      ;;
  esac
}

step_cloudinit_and_apt_clean() {
  echo "[13] Cloud-init cleanup & apt clean..."
  # cloud-init cleanup
  cloud-init clean --logs || true
  rm -rf /var/lib/cloud/* || true
  rm -f /etc/cloud/cloud.cfg.d/90_dpkg.cfg || true
  truncate -s 0 /etc/machine-id || true
  rm -f /var/lib/dbus/machine-id || true
  rm -f /etc/netplan/50-cloud-init.yaml || true
  cloud-init clean || true

  # apt clean and remove whiptail/dialog if present
  apt-get -y autoremove --purge whiptail dialog || true
  apt-get -y autoremove || true
  apt-get clean || true
  rm -rf /var/lib/apt/lists/* || true

  echo "✓ cloud-init cleaned and apt cache purged."
}

# ------------------------------
# Run-all (option 1)
# ------------------------------
run_all_steps() {
  local USER_DELETE_RESULT="skipped"

  step_update_upgrade          # [2]
  step_timezone                # [5]
  step_ssh_config              # [4]
  step_set_root_password       # [3]
  step_unzip_qga_getty         # [6]
  step_python_tools            # [7]
  step_install_docker          # [8]
  step_configure_docker_tcp    # [9]
  step_filebrowser_bundle      # [10]
  step_monitoring_bundle       # [11]

  # User deletion (ask y/n, optional but included in Run ALL)
  if step_delete_user_interactive; then
    USER_DELETE_RESULT="executed"
  else
    USER_DELETE_RESULT="skipped"
  fi

  step_cloudinit_and_apt_clean # [13]

  echo
  echo "====================================================="
  echo "✅ INSTALLATION OVERVIEW"
  echo "-----------------------------------------------------"
  echo "✔ System updated & upgraded"
  echo "✔ Timezone set: Europe/Amsterdam"
  echo "✔ SSH configured: root login + password auth enabled"
  echo "✔ Root password set/unlocked"
  echo "✔ Installed: zip, unzip, qemu-guest-agent, getty@tty1"
  echo "✔ Installed: Python3, pip, dev tools"
  echo "✔ Installed: Docker CE + Compose plugins"
  echo "✔ Docker listening on: unix:///var/run/docker.sock, tcp://0.0.0.0:2375"
  echo "✔ Filebrowser deployed (docker compose in /opt/filebrowser)"
  echo "✔ Monitoring deployed (docker compose in /opt/monitoring)"
  echo "✔ User deletion step: ${USER_DELETE_RESULT}"
  echo "✔ cloud-init cleaned, apt cache cleared"
  echo "====================================================="
  echo "⚠️  WARNING: Docker TCP (2375) is unsecured (no TLS)"
  echo "====================================================="
  echo
  echo "Do not forget to set cloud-init user, password and ip=dhcp in proxmox."
  echo
  echo "System will now power off..."
  sleep 5
  shutdown -h now
}

# ------------------------------
# Menu (no whiptail)
# ------------------------------
show_menu() {
  cat <<MENU

================= Debian Install Script =================
1) Run ALL steps (recommended; powers off at end)
2) Update & Upgrade System
3) Set root password (and unlock root)
4) Configure SSH (root login + password auth)
5) Set Timezone to Europe/Amsterdam
6) Install Zip/Unzip + QEMU Guest Agent (+ enable getty@tty1)
7) Install Python, pip & tools
8) Install Docker
9) Configure Docker Daemon (TCP 2375)
10) Install Filebrowser bundle (docker compose)
11) Install Monitoring bundle (docker compose)
12) Remove a user (prompt, optional)
13) Cloud-init cleanup & apt clean (also removes whiptail/dialog)
14) Exit
=========================================================
MENU
}

while true; do
  show_menu
  read -rp "Choose an option [1-14]: " CHOICE
  case "${CHOICE}" in
    1)  run_all_steps ;;
    2)  step_update_upgrade; press_enter ;;
    3)  step_set_root_password; press_enter ;;
    4)  step_ssh_config; press_enter ;;
    5)  step_timezone; press_enter ;;
    6)  step_unzip_qga_getty; press_enter ;;
    7)  step_python_tools; press_enter ;;
    8)  step_install_docker; press_enter ;;
    9)  step_configure_docker_tcp; press_enter ;;
    10) step_filebrowser_bundle; press_enter ;;
    11) step_monitoring_bundle; press_enter ;;
    12) step_delete_user_interactive; press_enter ;;
    13) step_cloudinit_and_apt_clean; press_enter ;;
    14) echo "Bye!"; exit 0 ;;
    *)  echo "Invalid choice." ;;
  esac
done
