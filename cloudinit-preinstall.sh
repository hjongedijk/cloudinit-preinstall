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

# --- Ensure whiptail is installed ---
if ! command -v whiptail &> /dev/null; then
  echo "Installing whiptail..."
  apt-get update && apt-get install -y whiptail
fi

# ------------------------------
# Functions (steps)
# ------------------------------

step_update_upgrade() {
  apt-get update && apt-get upgrade -y
  whiptail --msgbox "System updated successfully!" 10 50
}

step_timezone() {
  timedatectl set-timezone Europe/Amsterdam
  whiptail --msgbox "Timezone set to Europe/Amsterdam" 10 50
}

step_ssh_config() {
  whiptail --infobox "Configuring SSH (root login + password auth)..." 10 60
  SSH_FILE="/etc/ssh/sshd_config"
  sed -i 's/^[[:space:]]*PermitRootLogin[[:space:]].*/#&/' "$SSH_FILE"
  sed -i 's/^[[:space:]]*PasswordAuthentication[[:space:]].*/#&/' "$SSH_FILE"
  echo "PermitRootLogin yes" >> "$SSH_FILE"
  echo "PasswordAuthentication yes" >> "$SSH_FILE"
  systemctl restart ssh
  whiptail --msgbox "SSH configured: root login + password auth enabled. Service restarted." 12 70
}

step_set_root_password() {
  PW1=$(whiptail --passwordbox "Enter new root password:" 10 70 "" 3>&1 1>&2 2>&3) || { whiptail --msgbox "Cancelled." 8 40; return 0; }
  PW2=$(whiptail --passwordbox "Re-enter new root password:" 10 70 "" 3>&1 1>&2 2>&3) || { whiptail --msgbox "Cancelled." 8 40; return 0; }
  if [ -z "$PW1" ] || [ "$PW1" != "$PW2" ]; then
    whiptail --msgbox "Passwords empty or do not match. Try again." 10 60
    return 0
  fi
  echo "root:$PW1" | chpasswd
  passwd -u root 2>/dev/null || true
  whiptail --msgbox "Root password set (root account ensured unlocked)." 10 60
}

step_unzip_qga_getty() {
  apt-get update && apt-get install -y unzip zip qemu-guest-agent
  systemctl start qemu-guest-agent
  systemctl enable qemu-guest-agent
  systemctl enable getty@tty1.service
  systemctl start  getty@tty1.service
  whiptail --msgbox "Zip, Unzip, QEMU Guest Agent, and getty@tty1 installed & enabled successfully!" 12 75
}

step_python_tools() {
  whiptail --infobox "Installing Python, pip, and development tools..." 10 50
  apt-get update
  apt-get install -y python3 python3-pip python3-venv build-essential git curl
  whiptail --msgbox "Python, pip, and tools installed successfully!" 12 60
}

step_install_docker() {
  whiptail --infobox "Installing Docker, please wait..." 10 50
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  whiptail --msgbox "Docker installed successfully!" 10 60
}

step_configure_docker_tcp() {
  whiptail --infobox "Configuring Docker Daemon (TCP 2375)..." 10 50
  mkdir -p /etc/docker
  cat <<'EOF' > /etc/docker/daemon.json
{
  "hosts": ["unix:///var/run/docker.sock", "tcp://0.0.0.0:2375"]
}
EOF
  mkdir -p /etc/systemd/system/docker.service.d
  cat <<'EOF' > /etc/systemd/system/docker.service.d/docker.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd
EOF
  systemctl daemon-reload
  systemctl stop docker
  systemctl start docker
  systemctl enable docker
  whiptail --msgbox "Docker configured to listen on TCP (2375) and restarted successfully!" 12 70
}

ensure_unzip_curl() {
  if ! command -v unzip &>/dev/null; then apt-get update && apt-get install -y unzip zip; fi
  if ! command -v curl  &>/dev/null; then apt-get update && apt-get install -y curl; fi
}

step_filebrowser_bundle() {
  whiptail --infobox "Installing Filebrowser bundle..." 10 70
  ensure_unzip_curl
  mkdir -p /opt/filebrowser
  FILE_URL="https://example.com/filemanager.zip"   # <-- replace with real URL
  TARGET="/opt/filebrowser/filemanager.zip"
  if ! curl -fL "$FILE_URL" -o "$TARGET"; then
    whiptail --msgbox "Download failed from $FILE_URL" 10 70
    return 0
  fi
  (cd /opt/filebrowser && unzip -o filemanager.zip && rm -f filemanager.zip && docker compose up -d)
  whiptail --msgbox "Filebrowser bundle downloaded, extracted, and deployed with Docker Compose." 12 72
}

step_monitoring_bundle() {
  whiptail --infobox "Installing Monitoring bundle..." 10 70
  ensure_unzip_curl
  mkdir -p /opt/monitoring
  MONITOR_URL="https://example.com/monitoring.zip" # <-- replace with real URL
  TARGET="/opt/monitoring/monitoring.zip"
  if ! curl -fL "$MONITOR_URL" -o "$TARGET"; then
    whiptail --msgbox "Download failed from $MONITOR_URL" 10 70
    return 0
  fi
  (cd /opt/monitoring && unzip -o monitoring.zip && rm -f monitoring.zip && docker compose up -d)
  whiptail --msgbox "Monitoring bundle downloaded, extracted, and deployed with Docker Compose." 12 72
}

step_delete_user() {
  USER_TO_DEL=$(whiptail --inputbox "Enter the username to delete (this will remove the HOME directory too):" 10 70 "" 3>&1 1>&2 2>&3) || { whiptail --msgbox "Cancelled." 8 40; return 0; }
  if [ -z "$USER_TO_DEL" ]; then
    whiptail --msgbox "No username provided. Aborting." 10 50; return 0
  fi
  if [ "$USER_TO_DEL" = "root" ]; then
    whiptail --msgbox "Refusing to delete 'root' user." 10 50; return 0
  fi
  if ! id "$USER_TO_DEL" &>/dev/null; then
    whiptail --msgbox "User '$USER_TO_DEL' does not exist." 10 60; return 0
  fi
  USER_HOME="$(getent passwd "$USER_TO_DEL" | cut -d: -f6)"
  if whiptail --yesno "Are you sure you want to delete user '$USER_TO_DEL' and remove HOME: ${USER_HOME:-N/A} ?" 12 75; then
    loginctl terminate-user "$USER_TO_DEL" 2>/dev/null || true
    pkill -u "$USER_TO_DEL" 2>/dev/null || true
    if userdel -r "$USER_TO_DEL"; then
      crontab -r -u "$USER_TO_DEL" 2>/dev/null || true
      if [ -n "$USER_HOME" ] && [ -d "$USER_HOME" ]; then
        rm -rf --one-file-system "$USER_HOME"
      fi
      rm -f "/var/mail/$USER_TO_DEL" 2>/dev/null || true
      rm -rf "/var/spool/cron/crontabs/$USER_TO_DEL" 2>/dev/null || true
      whiptail --msgbox "User '$USER_TO_DEL' removed. Home directory and leftovers cleaned." 12 75
    else
      whiptail --msgbox "Failed to delete user '$USER_TO_DEL'. Check processes or separate filesystems." 12 75
    fi
  fi
}

# ------------------------------
# Run-all (option 1)
# ------------------------------
run_all_steps() {
  step_update_upgrade
  step_timezone
  step_ssh_config
  step_set_root_password
  step_unzip_qga_getty
  step_python_tools
  step_install_docker
  step_configure_docker_tcp
  step_filebrowser_bundle
  step_monitoring_bundle
  whiptail --msgbox "✅ All steps completed (except user deletion, which is manual by design)." 12 70
}

# ------------------------------
# Menu
# ------------------------------
while true; do
  CHOICE=$(whiptail --title "Debian Install Script" --menu "Choose an option:" 26 100 16 \
    "1"  "Run ALL steps (sequence below)" \
    "2"  "Update & Upgrade System" \
    "3"  "Set root password (and unlock root)" \
    "4"  "Configure SSH (root login + password auth)" \
    "5"  "Set Timezone to Europe/Amsterdam" \
    "6"  "Install Zip/Unzip + QEMU Guest Agent (+ enable getty@tty1)" \
    "7"  "Install Python, pip & tools" \
    "8"  "Install Docker" \
    "9"  "Configure Docker Daemon (TCP 2375)" \
    "10" "Install Filebrowser bundle (docker compose)" \
    "11" "Install Monitoring bundle (docker compose)" \
    "12" "Remove a user (prompt) and delete home directory" \
    "13" "Exit" 3>&1 1>&2 2>&3)

  if [ $? -ne 0 ]; then
    echo "User canceled."
    exit
  fi

  case $CHOICE in
    1)  run_all_steps ;;
    2)  step_update_upgrade ;;
    3)  step_set_root_password ;;
    4)  step_ssh_config ;;
    5)  step_timezone ;;
    6)  step_unzip_qga_getty ;;
    7)  step_python_tools ;;
    8)  step_install_docker ;;
    9)  step_configure_docker_tcp ;;
    10) step_filebrowser_bundle ;;
    11) step_monitoring_bundle ;;
    12) step_delete_user ;;
    13) exit ;;
  esac
done
