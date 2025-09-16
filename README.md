# Proxmox Debian VM Setup Guide

This guide explains how to deploy Debian VMs on **Proxmox VE (PVE)** using community scripts and configure them with cloud-init.

---

## Proxmox > PVE > Shell

### Debian 12
[Community Script Link](https://community-scripts.github.io/ProxmoxVE/scripts?id=debian-vm&category=Operating+Systems)

```bash
bash -c "$(wget -qLO - https://github.com/community-scripts/ProxmoxVE/raw/main/scripts/debian-vm.sh)"
```

This script automates the creation of a Debian 12 VM with optimized defaults for Proxmox.

---

### Debian 13
[Community Script Link](https://community-scripts.github.io/ProxmoxVE/scripts?id=debian-13-vm)

```bash
bash -c "$(wget -qLO - https://github.com/community-scripts/ProxmoxVE/raw/main/scripts/debian-13-vm.sh)"
```

This script creates a Debian 13 VM and applies recommended configuration for seamless integration in Proxmox.

---

## Running the Cloud-Init Preinstall Script

Once your VM has been created, open the console:

**Console > xterm.js**

Run the following command inside the VM to apply the preinstall script:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/hjongedijk/cloudinit-preinstall/main/cloudinit-preinstall.sh)"
```

This script prepares the VM for cloud-init usage, applying default settings and configurations.

---

## Notes
- Ensure your Proxmox node has internet access for fetching scripts.
- Review the scripts before running to understand the applied configuration.
- Both Debian 12 and 13 scripts support Proxmox community best practices.
