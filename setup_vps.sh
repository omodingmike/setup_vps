#!/bin/bash

################################################################################
# 🚀 Ubuntu VPS Security Setup Script
#
# This script automates the hardening of a new Ubuntu server.
# It MUST be run as the root user.
#
# Usage:
# 1. Edit the "CONFIGURATION" section below with your details.
# 2. Upload this script to your new server (e.g., using scp).
#    scp setup_vps.sh root@YOUR_SERVER_IP:/root/
# 3. Log in as root, make the script executable, and run it:
#    ssh root@YOUR_SERVER_IP
#    chmod +x /root/setup_vps.sh
#    /root/setup_vps.sh
#
################################################################################

# --- ☢️ START CONFIGURATION ☢️ ---

# Set the name of your new non-root user
NEW_USER="omoding"

# Set the new port you want to use for SSH (e.g., 2222)
SSH_PORT="2222"

# ❗️ PASTE YOUR PUBLIC KEY HERE ❗️
# Get this from your local Mac: cat ~/.ssh/adam_rsa.pub
PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQD...[rest of your key]... user@host"

# --- 🔥 END CONFIGURATION 🔥 ---


# Stop script on any error
set -e

# Ensure script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Exiting." >&2
  exit 1
fi

echo "--- 1. Updating System Packages ---"
apt update
apt upgrade -y

echo "--- 2. Creating New User '$NEW_USER' ---"
# Create the user (this part is interactive, will ask for a password)
adduser $NEW_USER

# Grant sudo privileges
usermod -aG sudo $NEW_USER
echo "User $NEW_USER created and added to sudo group."

echo "--- 3. Setting Up SSH Key for $NEW_USER ---"
# Create .ssh directory and set permissions
mkdir -p /home/$NEW_USER/.ssh
chmod 700 /home/$NEW_USER/.ssh

# Create authorized_keys file and add the public key
echo "$PUBLIC_KEY" > /home/$NEW_USER/.ssh/authorized_keys
chmod 600 /home/$NEW_USER/.ssh/authorized_keys

# Set correct ownership
chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.ssh

echo "SSH key added and permissions set."

echo "--- 4. Hardening SSH Configuration ---"
# Modify the main sshd_config file
sed -i "s/^#*Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config

# Fix cloud-init overrides that force password auth
# This searches for any file in sshd_config.d that enables passwords and disables it.
grep -lR "PasswordAuthentication yes" /etc/ssh/sshd_config.d/ | while read -r line; do
  echo "Fixing $line..."
  sed -i "s/PasswordAuthentication yes/PasswordAuthentication no/g" "$line"
done

# Restart SSH service
# Check for systemd socket activation first
if systemctl list-unit-files | grep -q 'ssh.socket'; then
  echo "Restarting ssh.socket (systemd socket activation detected)..."
  systemctl daemon-reload
  systemctl restart ssh.socket
else
  echo "Restarting ssh.service..."
  systemctl restart ssh.service
fi

echo "SSH hardened. New port is $SSH_PORT. Root login and passwords disabled."

echo "--- 5. Configuring UFW Firewall ---"
# Install UFW if not present
apt install ufw -y

# Set default policies
ufw default deny incoming
ufw default allow outgoing

# Allow essential ports
ufw allow $SSH_PORT/tcp
ufw allow http
ufw allow https

# Enable the firewall non-interactively
yes | ufw enable
echo "Firewall enabled and configured."

echo "--- 6. Installing and Configuring Fail2Ban ---"
apt install fail2ban -y

# Create the jail.local file with our custom SSH jail
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port    = $SSH_PORT
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

systemctl restart fail2ban
echo "Fail2Ban installed and configured to protect port $SSH_PORT."

echo "--- 7. Enabling Automatic Security Updates ---"
apt install unattended-upgrades -y
# Set up automatic updates non-interactively
echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades
echo "Automatic security updates enabled."

echo ""
echo "✅ --- VPS Hardening Complete! --- ✅"
echo ""
echo "⚠️ IMPORTANT ⚠️"
echo "You will be disconnected. Log back in with:"
echo "ssh -p $SSH_PORT -i /path/to/your/private_key $NEW_USER@YOUR_SERVER_IP"
echo ""