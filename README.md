# Proxmox Debian VM Setup & Cloud-Init Preinstall

This repository provides a fast path to deploy Debian 12/13 VMs on **Proxmox VE** and prepare them for **cloud-init** with an interactive, menu-driven preinstall script.

- Creates a Debian VM using the community one-liners (Debian 12 or 13)
- Runs `cloudinit-preinstall.sh` inside the VM to apply sane defaults
- (Optional) Deploys **Filebrowser** and a **Monitoring** stack via Docker
- Cleans cloud-init state so your template is ready for cloning

---

## ✅ Quick Start

### 1) Create a Debian VM in Proxmox

**Debian 12**
```bash
bash -c "$(wget -qLO - https://github.com/community-scripts/ProxmoxVE/raw/main/scripts/debian-vm.sh)"
```
<sub>(Source: [Proxmox VE Helper-Scripts](https://community-scripts.github.io/ProxmoxVE/scripts?id=debian-vm&category=Operating+Systems))</sub>

**Debian 13**
```bash
bash -c "$(wget -qLO - https://github.com/community-scripts/ProxmoxVE/raw/main/scripts/debian-13-vm.sh)"
```
<sub>(Source: [Proxmox VE Helper-Scripts](https://community-scripts.github.io/ProxmoxVE/scripts?id=debian-13-vm))</sub>

> These community scripts create a VM with Proxmox-friendly defaults.

---

### 2) Run the Cloud-Init Preinstall (inside the VM)

Open **Proxmox → your VM → Console (xterm.js)** and log in as `root`, then:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/hjongedijk/cloudinit-preinstall/main/cloudinit-preinstall.sh)"
```

- Choose **1) Run ALL steps** or run individual steps as needed.
- At the end you’ll get a clear **installation overview** and an **optional shutdown** prompt.

---

## 🧰 What the script does

The script is interactive and idempotent where possible.  

### When run as **non-root**
- Prompts to set/unlock the **root password**
- Enables **SSH root login + password auth**
- Restarts **SSH**
- Prints follow-up steps and asks to logout

### When run as **root**
Runs full setup (via menu or run-all):

1. 🔄 Update & upgrade system packages  
2. 📦 Install base tools (`sudo`, `curl`, `wget`, `git`, `htop`, `fail2ban`, etc.)  
3. 🔐 Set and unlock `root` password  
4. 🔧 Configure SSH (`PermitRootLogin` + `PasswordAuthentication` **enabled**)  
5. 🧹 Remove an existing user (optional, interactive), if VM only needs to have **root** user  
6. 🕰️  Set timezone → `Europe/Amsterdam`  
7. 🧰 Install `qemu-guest-agent`, `zip`, `unzip`, and **enable** `getty@tty1` for **Default (VNC console)** 
8. 🐍 Install Python 3, pip, venv, dev tools  
9. 🐳 Install Docker CE + Compose plugins  
10. 🔌 Configure Docker to listen on `unix:///var/run/docker.sock` and `tcp://0.0.0.0:2375` (**⚠️ insecure**)  
11. 👥 Grant Docker access (via group or chmod 666)  
12. 📁 Deploy **Filebrowser** bundle (`/opt/filebrowser`)  
13. 📊 Deploy **Monitoring** bundle (`/opt/monitoring`)  
14. 🧽 Clean cloud-init state and apt cache  
15. 📴 Prompt for shutdown (optional)  

---

## ⚠️ Notes & Warnings

- Always run as **root** for the full installer.  
- Docker TCP (2375) is **unsecured** — only use on trusted networks.  
- After running, configure cloud-init in Proxmox (`user`, `password`, `ip=dhcp`) and **regenerate image**.  
- After enabling **getty@tty1** you can safely remove the serial port and set Display → **Default (VNC console)**.  

---

## 📋 Example Workflow

1. Deploy Debian VM (12 or 13) via community script.  
2. Boot the VM, open **Console (xterm.js)**, log in as `root`.  
3. Run the preinstall script:  
   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/hjongedijk/cloudinit-preinstall/main/cloudinit-preinstall.sh)"
   ```  
4. Choose **Run ALL** (or step through interactively).  
5. Shut down the VM when done.  
6. Configure **cloud-init** in Proxmox and regenerate image. 
7. Optional remove the **Serial Port (serial0)** from VM Hardware and set **Display** to Default.
8. Convert the VM to template.
8. VM template is now **ready for cloning & production use** 🚀  
