#!/bin/bash
set -Eeuo pipefail

echo "========================================="
echo "       Hardened VPS Setup Script         "
echo "========================================="

if [ "$EUID" -ne 0 ]; then
  echo "Error: setup.sh must be run as root. Use sudo or log in as root."
  exit 1
fi

# --- INTERACTIVE PROMPTS ---

# 1. Prompt for User (with default)
read -p "Enter the new username [default: deploy]: " input_user
NEW_USER="${input_user:-deploy}"
if ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
  echo "Error: Invalid Linux username: $NEW_USER"
  exit 1
fi

# 2. Prompt for Port (with default)
read -p "Enter custom SSH port [default: 7589]: " input_port
CUSTOM_SSH_PORT="${input_port:-7589}"
if ! [[ "$CUSTOM_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$CUSTOM_SSH_PORT" -lt 1 ] || [ "$CUSTOM_SSH_PORT" -gt 65535 ]; then
  echo "Error: SSH port must be a number from 1 to 65535."
  exit 1
fi

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
USER_HOME="/home/$NEW_USER"
USER_SSH_DIR="$USER_HOME/.ssh"
AUTHORIZED_KEYS="$USER_SSH_DIR/authorized_keys"
mkdir -p "$USER_SSH_DIR"
touch "$AUTHORIZED_KEYS"
if grep -qxF "$SSH_PUBLIC_KEY" "$AUTHORIZED_KEYS"; then
  echo "SSH Public Key already authorized for $NEW_USER."
else
  printf '%s\n' "$SSH_PUBLIC_KEY" >> "$AUTHORIZED_KEYS"
  echo "SSH Public Key added."
fi
chown -R "$NEW_USER":"$NEW_USER" "$USER_SSH_DIR"
chmod 700 "$USER_SSH_DIR"
chmod 600 "$AUTHORIZED_KEYS"

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
set_sshd_option() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"

  if grep -qE "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${value}|" "$file"
  else
    printf '%s %s\n' "$key" "$value" >> "$file"
  fi
}

set_sshd_option Port "$CUSTOM_SSH_PORT"
set_sshd_option PermitRootLogin no
set_sshd_option PasswordAuthentication no
set_sshd_option PubkeyAuthentication yes

# Disable Password Authentication in drop-in files to prevent cloud-init overrides
mkdir -p /etc/ssh/sshd_config.d
echo "PasswordAuthentication no" > /etc/ssh/sshd_config.d/60-custom-disable-pass.conf

# 7. Firewall (UFW)
if ! command -v ufw &>/dev/null; then
  apt install ufw -y
fi
echo "Configuring Firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow "$CUSTOM_SSH_PORT"/tcp
ufw allow http
ufw allow https
if ufw status | grep -q "active"; then
  echo "Firewall is already active."
else
  echo "y" | ufw enable
fi

# 8. Fail2Ban (Installs latest available in OS repo)
if ! command -v fail2ban-server &>/dev/null; then
  apt install fail2ban -y
fi
echo "Configuring Fail2Ban..."
cat <<EOM > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $CUSTOM_SSH_PORT
maxretry = 5
bantime = 1h
EOM
systemctl enable --now fail2ban
systemctl restart fail2ban

# 9. Final Cleanup & Restart
systemctl restart ssh || systemctl restart sshd

echo "-------------------------------------------------------"
echo "Setup Complete & Verified!"
echo "Login: ssh -p $CUSTOM_SSH_PORT $NEW_USER@$(hostname -I | awk '{print $1}')"
echo "-------------------------------------------------------"
