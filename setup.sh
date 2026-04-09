#!/bin/bash

echo "========================================="
echo "       Hardened VPS Setup Script         "
echo "========================================="

# --- INTERACTIVE PROMPTS ---

# 1. Prompt for User (with default)
read -p "Enter the new username [default: deploy]: " input_user
NEW_USER="${input_user:-deploy}"

# 2. Prompt for Port (with default)
read -p "Enter custom SSH port [default: 7589]: " input_port
CUSTOM_SSH_PORT="${input_port:-7589}"

# 3. Prompt for SSH Key (Required)
while true; do
  read -p "Paste the SSH Public Key for $NEW_USER: " SSH_PUBLIC_KEY
  if [ -n "$SSH_PUBLIC_KEY" ]; then
    break
  else
    echo "Error: SSH Public Key cannot be empty. Please try again."
  fi
done

echo ""
echo "Starting setup with User: $NEW_USER on Port: $CUSTOM_SSH_PORT..."
echo ""

# --- BEGIN SYSTEM CONFIGURATION ---

# 1. Update & Upgrade System to Latest Packages
export DEBIAN_FRONTEND=noninteractive
echo "Updating package lists and upgrading system packages to latest..."
apt update && apt upgrade -y
# Ensure curl is installed for the Docker script
apt install curl -y

# 2. Create User (Check if exists)
if id "$NEW_USER" &>/dev/null; then
  echo "User $NEW_USER already exists. Skipping creation."
else
  echo "Creating user: $NEW_USER"
  useradd -m -s /bin/bash "$NEW_USER"
  passwd -l "$NEW_USER"
  usermod -aG sudo "$NEW_USER"
fi

# 3. Setup SSH (Check if key already present)
mkdir -p /home/"$NEW_USER"/.ssh
if grep -q "$SSH_PUBLIC_KEY" /home/"$NEW_USER"/.ssh/authorized_keys 2>/dev/null; then
  echo "SSH Public Key already authorized for $NEW_USER."
else
  echo "$SSH_PUBLIC_KEY" >> /home/"$NEW_USER"/.ssh/authorized_keys
  echo "SSH Public Key added."
fi
chown -R "$NEW_USER":"$NEW_USER" /home/"$NEW_USER"/.ssh
chmod 700 /home/"$NEW_USER"/.ssh
chmod 600 /home/"$NEW_USER"/.ssh/authorized_keys

# 4. Docker Installation - Fetching LATEST from Official Repo
if command -v docker &> /dev/null; then
  echo "Docker is already installed."
else
  echo "Installing the LATEST Docker directly from Docker's official repository..."
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  rm get-docker.sh
  systemctl enable --now docker
fi

# Add user to docker group if not already a member
if groups "$NEW_USER" | grep &>/dev/null "\bdocker\b"; then
  echo "User $NEW_USER is already in the docker group."
else
  usermod -aG docker "$NEW_USER"
  echo "User $NEW_USER added to docker group."
fi

# 5. Passwordless Sudo for the User
if [ -f /etc/sudoers.d/"$NEW_USER" ]; then
  echo "Passwordless sudo rule already exists for $NEW_USER."
else
  echo "$NEW_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/"$NEW_USER"
  chmod 440 /etc/sudoers.d/"$NEW_USER"
  echo "Passwordless sudo rule created for $NEW_USER."
fi

# Clean up the old docker-only sudoers file if you ran an older version of this script
if [ -f /etc/sudoers.d/deploy-docker ]; then
  rm /etc/sudoers.d/deploy-docker
fi

# 6. Harden SSH Configuration
echo "Applying SSH hardening..."
sed -i "s/^#*Port.*/Port $CUSTOM_SSH_PORT/" /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Disable Password Authentication in drop-in files to prevent cloud-init overrides
echo "PasswordAuthentication no" > /etc/ssh/sshd_config.d/60-custom-disable-pass.conf

# 7. Firewall (UFW)
if ufw status | grep -q "active"; then
  echo "Firewall is already active."
else
  echo "Configuring Firewall..."
  apt install ufw -y
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$CUSTOM_SSH_PORT"/tcp
  ufw allow http
  ufw allow https
  echo "y" | ufw enable
fi

# 8. Fail2Ban (Installs latest available in OS repo)
if [ -f /etc/fail2ban/jail.local ]; then
  echo "Fail2Ban configuration already exists."
else
  echo "Configuring Fail2Ban..."
  apt install fail2ban -y
  cat <<EOM > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $CUSTOM_SSH_PORT
maxretry = 5
bantime = 1h
EOM
  systemctl restart fail2ban
fi

# 9. Final Cleanup & Restart
systemctl restart ssh

echo "-------------------------------------------------------"
echo "Setup Complete & Verified!"
echo "Login: ssh -p $CUSTOM_SSH_PORT $NEW_USER@$(hostname -I | awk '{print $1}')"
echo "-------------------------------------------------------"