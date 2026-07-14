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

# Back up sshd_config once so a bad edit is always recoverable.
if [ ! -f /etc/ssh/sshd_config.bak ]; then
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
  echo "Backed up sshd_config to /etc/ssh/sshd_config.bak"
fi

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
set_sshd_option AllowUsers "$NEW_USER"
set_sshd_option MaxAuthTries 3
set_sshd_option LoginGraceTime 20
set_sshd_option KbdInteractiveAuthentication no
set_sshd_option ChallengeResponseAuthentication no
set_sshd_option X11Forwarding no
set_sshd_option AllowAgentForwarding no
set_sshd_option PermitEmptyPasswords no
set_sshd_option ClientAliveInterval 300
set_sshd_option ClientAliveCountMax 2

# Disable Password Authentication in drop-in files to prevent cloud-init overrides
mkdir -p /etc/ssh/sshd_config.d
echo "PasswordAuthentication no" > /etc/ssh/sshd_config.d/60-custom-disable-pass.conf

# Validate the resulting config now — never restart sshd with a broken config.
if ! sshd -t; then
  echo "Error: sshd configuration is invalid after hardening. Restoring backup."
  cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
  exit 1
fi

# 7. Firewall (UFW)
if ! command -v ufw &>/dev/null; then
  apt install ufw -y
fi
echo "Configuring Firewall..."
ufw default deny incoming
ufw default allow outgoing
# "limit" rate-limits repeated connections from the same IP (brute-force defense).
ufw limit "$CUSTOM_SSH_PORT"/tcp
ufw allow http
ufw allow https
if ufw status | grep -q "active"; then
  echo "Firewall is already active."
else
  echo "y" | ufw enable
fi

# 8. Fail2Ban (best-effort - never abort the whole hardening run if unavailable)
fail2ban_diagnostics() {
  echo "WARNING: fail2ban could not be installed from apt. Diagnostics:"
  echo "  OS: $(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '\"')"
  echo "  apt-cache policy fail2ban:"
  apt-cache policy fail2ban 2>&1 | sed 's/^/    /' || true
  echo "  Enabled apt sources/components:"
  grep -rhE '^(deb |Suites:|Components:|Types:|URIs:)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | sed 's/^/    /' || true
}

install_fail2ban() {
  command -v fail2ban-server &>/dev/null && return 0

  # On Ubuntu, fail2ban lives in the "universe" component; enable it if missing.
  # (Debian ships it in "main", so this is a no-op / harmless there.)
  if grep -qiE '(^|_)ubuntu' /etc/os-release 2>/dev/null; then
    if ! command -v add-apt-repository &>/dev/null; then
      apt install -y software-properties-common || true
    fi
    if command -v add-apt-repository &>/dev/null; then
      add-apt-repository -y universe || true
    fi
  fi

  # Refresh the index, then try the install.
  apt update || true
  local candidate
  candidate="$(apt-cache policy fail2ban 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
    fail2ban_diagnostics
    return 1
  fi

  if apt install -y fail2ban; then
    return 0
  fi

  fail2ban_diagnostics
  return 1
}

if install_fail2ban; then
  echo "Configuring Fail2Ban..."
  cat <<EOM > /etc/fail2ban/jail.local
[DEFAULT]
backend = systemd
# Never lock out localhost. Add your own static IP here to whitelist it.
ignoreip = 127.0.0.1/8 ::1
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = $CUSTOM_SSH_PORT
maxretry = 5
bantime = 1h

# Escalating bans for repeat offenders across all jails.
[recidive]
enabled = true
bantime = 1w
findtime = 1d
maxretry = 5
EOM
  systemctl enable --now fail2ban
  systemctl restart fail2ban
else
  echo "WARNING: Skipping Fail2Ban setup. SSH is still protected by key-only auth,"
  echo "         UFW rate-limiting, and MaxAuthTries. You can install it later with:"
  echo "         sudo apt update && sudo apt install fail2ban"
fi

# 9. Kernel & Network Hardening (sysctl)
echo "Applying kernel and network hardening..."
cat <<EOM > /etc/sysctl.d/99-hardening.conf
# Reverse-path filtering (anti IP spoofing)
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
# SYN flood protection
net.ipv4.tcp_syncookies=1
# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
# Do not send ICMP redirects (not a router)
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
# Ignore source-routed packets
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
# Log martian (spoofed/impossible) packets
net.ipv4.conf.all.log_martians=1
# Ignore broadcast ICMP (smurf attack defense)
net.ipv4.icmp_echo_ignore_broadcasts=1
# Protect against bad ICMP error messages
net.ipv4.icmp_ignore_bogus_error_responses=1
# Full ASLR
kernel.randomize_va_space=2
EOM
sysctl --system >/dev/null

# 10. Automatic Security Updates
echo "Enabling automatic security updates..."
apt install unattended-upgrades -y
cat <<EOM > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOM
systemctl enable --now unattended-upgrades || true

# 11. Final Cleanup & Restart
# Re-validate sshd before the restart as a final safety check.
if ! sshd -t; then
  echo "Error: sshd config invalid at final check. Not restarting SSH. Restoring backup."
  cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
  exit 1
fi
systemctl restart ssh || systemctl restart sshd

echo "-------------------------------------------------------"
echo "Setup Complete & Verified!"
echo "Login: ssh -p $CUSTOM_SSH_PORT $NEW_USER@$(hostname -I | awk '{print $1}')"
echo "-------------------------------------------------------"
