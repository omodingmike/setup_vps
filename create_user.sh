#!/bin/bash
set -Eeuo pipefail

echo "========================================="
echo "       Create Sudo User Script           "
echo "========================================="

if [ "$EUID" -ne 0 ]; then
  echo "Error: create_user.sh must be run as root. Use sudo or log in as root."
  exit 1
fi

read -p "Enter the new username [default: deploy]: " input_user
NEW_USER="${input_user:-deploy}"

if ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
  echo "Error: Invalid Linux username: $NEW_USER"
  exit 1
fi

while true; do
  read -p "Paste the SSH Public Key for $NEW_USER: " SSH_PUBLIC_KEY
  if [ -n "$SSH_PUBLIC_KEY" ]; then
    break
  else
    echo "Error: SSH Public Key cannot be empty. Please try again."
  fi
done

if ! command -v sudo &>/dev/null; then
  echo "Installing sudo..."
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt install sudo -y
fi

if id "$NEW_USER" &>/dev/null; then
  echo "User $NEW_USER already exists. Skipping creation."
else
  echo "Creating user: $NEW_USER"
  useradd -m -s /bin/bash "$NEW_USER"
fi

passwd -l "$NEW_USER" >/dev/null
echo "Password login locked for $NEW_USER."

if id -nG "$NEW_USER" | grep -qw sudo; then
  echo "User $NEW_USER is already in the sudo group."
else
  usermod -aG sudo "$NEW_USER"
  echo "User $NEW_USER added to the sudo group."
fi

USER_HOME="$(getent passwd "$NEW_USER" | cut -d: -f6)"
USER_SSH_DIR="$USER_HOME/.ssh"
AUTHORIZED_KEYS="$USER_SSH_DIR/authorized_keys"

mkdir -p "$USER_SSH_DIR"
touch "$AUTHORIZED_KEYS"

if grep -qxF "$SSH_PUBLIC_KEY" "$AUTHORIZED_KEYS"; then
  echo "SSH Public Key already authorized for $NEW_USER."
else
  printf '%s\n' "$SSH_PUBLIC_KEY" >> "$AUTHORIZED_KEYS"
  echo "SSH Public Key added for $NEW_USER."
fi

chown -R "$NEW_USER":"$NEW_USER" "$USER_SSH_DIR"
chmod 700 "$USER_SSH_DIR"
chmod 600 "$AUTHORIZED_KEYS"

SUDOERS_FILE="/etc/sudoers.d/$NEW_USER"
SUDOERS_RULE="$NEW_USER ALL=(ALL) NOPASSWD: ALL"

if [ -f "$SUDOERS_FILE" ] && grep -qxF "$SUDOERS_RULE" "$SUDOERS_FILE"; then
  echo "Passwordless sudo rule already exists for $NEW_USER."
else
  echo "$SUDOERS_RULE" > "$SUDOERS_FILE"
  chmod 440 "$SUDOERS_FILE"

  if visudo -cf "$SUDOERS_FILE" >/dev/null; then
    echo "Passwordless sudo rule created for $NEW_USER."
  else
    rm -f "$SUDOERS_FILE"
    echo "Error: sudoers validation failed. Removed $SUDOERS_FILE."
    exit 1
  fi
fi

echo "-------------------------------------------------------"
echo "User $NEW_USER is ready with sudo privileges."
echo "-------------------------------------------------------"
