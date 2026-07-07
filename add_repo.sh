#!/bin/bash
set -Eeuo pipefail

echo "========================================="
echo "       Add New Repository Script         "
echo "========================================="

# ----------------------------
# HELPER FUNCTIONS
# ----------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if [ "$EUID" -eq 0 ]; then
    echo "❌ Do not run this script as root."
    echo "   Log in as your deploy user first, then run: ./add_repo.sh"
    exit 1
fi

# ----------------------------
# INTERACTIVE CONFIGURATION
# ----------------------------

# 1. Project Path
read -p "Enter full project path (e.g., $HOME/my-new-app): " TARGET_DIR
if [ -z "$TARGET_DIR" ]; then
    echo "❌ Project path is required."
    exit 1
fi

# 2. GitHub Repository
read -p "Enter GitHub Repo (username/repo): " input_repo
if [ -z "$input_repo" ]; then
    echo "❌ Repo name is required."
    exit 1
fi
REPO="${input_repo#https://github.com/}"
REPO="${REPO#http://github.com/}"
REPO="${REPO#git@github.com:}"
REPO="${REPO%.git}"
REPO="${REPO%/}"
if [[ "$REPO" != */* || "$REPO" == *" "* ]]; then
    echo "❌ Repo must be in owner/repo format."
    exit 1
fi

# 3. Docker Network
read -p "Enter Docker Network Name [default: smartduuka_network]: " input_network
NETWORK_NAME="${input_network:-smartduuka_network}"

# ----------------------------
# DERIVED VARIABLES
# ----------------------------
REPO_ALIAS="${REPO//\//_}"
REPO_URL="git@github-${REPO_ALIAS}:${REPO}.git"
CICD_KEY_PATH="$HOME/.ssh/id_ed25519_cicd_deploy"
SSH_DIR="$HOME/.ssh"
SSH_LOGIN_USER="$(id -un)"

echo ""
log "🚀 Setting up $REPO at $TARGET_DIR..."
echo ""

# ----------------------------
# 1. SSH KEY GENERATION
# ----------------------------
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

KEY_PATH="$SSH_DIR/id_ed25519_$REPO_ALIAS"
HOST_ALIAS="github-$REPO_ALIAS"

if [ ! -f "$KEY_PATH" ]; then
  log "🔑 Generating unique SSH key for $REPO..."
  ssh-keygen -t ed25519 -C "deploy-$REPO_ALIAS" -f "$KEY_PATH" -N ""
  eval "$(ssh-agent -s)" &>/dev/null
  ssh-add "$KEY_PATH" &>/dev/null
else
  log "✅ SSH key for $REPO_ALIAS already exists."
fi
chmod 600 "$KEY_PATH"
chmod 644 "${KEY_PATH}.pub"

if [ ! -f "$CICD_KEY_PATH" ]; then
  log "🔑 CI/CD Private Key not found at $CICD_KEY_PATH. Generating it now..."
  ssh-keygen -t ed25519 -C "cicd-auto-deploy" -f "$CICD_KEY_PATH" -N ""
else
  log "✅ CI/CD key already exists."
fi
chmod 600 "$CICD_KEY_PATH"
chmod 644 "${CICD_KEY_PATH}.pub"

AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
CICD_PUBLIC_KEY="$(cat "${CICD_KEY_PATH}.pub")"
if ! grep -qxF "$CICD_PUBLIC_KEY" "$AUTHORIZED_KEYS"; then
  log "🔐 Authorizing CI/CD key for SSH login..."
  printf '%s\n' "$CICD_PUBLIC_KEY" >> "$AUTHORIZED_KEYS"
else
  log "✅ CI/CD key is already authorized for SSH login."
fi

# Update SSH Config
SSH_CONFIG="$SSH_DIR/config"
if ! grep -qF "Host $HOST_ALIAS" "$SSH_CONFIG" 2>/dev/null; then
  log "📝 Adding config entry for $HOST_ALIAS..."
  cat <<EOF >> "$SSH_CONFIG"

Host $HOST_ALIAS
    HostName github.com
    User git
    IdentityFile $KEY_PATH
    IdentitiesOnly yes
EOF
fi
chmod 600 "$SSH_CONFIG"

# ----------------------------
# 2. GITHUB SETUP INSTRUCTIONS (BEFORE CLONING)
# ----------------------------
echo ""
echo "================================================================="
echo "                 GITHUB SETUP INSTRUCTIONS                       "
echo "================================================================="
echo " STEP 1: REPOSITORY ACCESS (READ ONLY)"
echo " -> Go to: https://github.com/$REPO/settings/keys"
echo " -> Click 'Add deploy key'"
echo " -> Paste this exact PUBLIC key:"
echo "-----------------------------------------------------------------"
cat "${KEY_PATH}.pub"
echo "-----------------------------------------------------------------"
echo ""
echo " STEP 2: CI/CD AUTOMATION (GITHUB ACTIONS)"
echo " -> Go to: https://github.com/$REPO/settings/secrets/actions"
echo " -> Click 'New repository secret'"
echo " -> Name it 'DEPLOY_KEY' and paste this exact PRIVATE key:"
echo "-----------------------------------------------------------------"
cat "$CICD_KEY_PATH"
echo "-----------------------------------------------------------------"
echo "================================================================="
echo ""
read -p "Press [Enter] once BOTH keys have been added to GitHub..."
echo ""

# ----------------------------
# 3. VERIFY CONNECTION & CLONE
# ----------------------------
log "🧪 Verifying GitHub SSH Connection..."
KNOWN_HOSTS="$SSH_DIR/known_hosts"
touch "$KNOWN_HOSTS"
if ! ssh-keygen -F github.com -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
  ssh-keyscan -H github.com >> "$KNOWN_HOSTS" 2>/dev/null
fi
chmod 644 "$KNOWN_HOSTS"
set +e
ssh -T "git@github-${REPO_ALIAS}" 2>&1 | grep -q "successfully authenticated" && log "✅ Repo SSH auth successful."
set -e

# Ensure Network Exists
sudo docker network ls --format '{{.Name}}' | grep -wq "$NETWORK_NAME" || sudo docker network create "$NETWORK_NAME"

# Clone or Update Directory
mkdir -p "$(dirname "$TARGET_DIR")"
if [ ! -d "$TARGET_DIR/.git" ]; then
  log "📥 Cloning $REPO_URL to $TARGET_DIR..."
  git clone "$REPO_URL" "$TARGET_DIR"
else
  log "🔄 Updating existing directory $TARGET_DIR..."
  cd "$TARGET_DIR"
  git remote set-url origin "$REPO_URL"
  git pull
fi

# ----------------------------
# 4. GENERATE CI/CD AUTOMATION SCRIPT
# ----------------------------
UPDATE_SCRIPT="$HOME/update_${REPO_ALIAS}.sh"
log "📝 Generating CI/CD script at $UPDATE_SCRIPT..."

cat << EOF > "$UPDATE_SCRIPT"
#!/bin/bash
set -Eeuo pipefail
echo "🚀 Starting CI/CD Deployment for $REPO..."
cd "$TARGET_DIR"
git pull

if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
    sudo docker compose build
    sudo docker compose up -d --remove-orphans
else
    echo "⚠️ No docker-compose file found. Skipping docker build."
fi
echo "✅ Update complete!"
EOF

chmod +x "$UPDATE_SCRIPT"

echo ""
echo " 💡 CI/CD Reminder:"
echo " Your global CI/CD GitHub Action key is already set up on this server."
echo " Just trigger this script in your GitHub Actions YAML:"
echo " ssh $SSH_LOGIN_USER@your-server-ip \"$UPDATE_SCRIPT\""
echo "================================================================="
echo ""
log "✅ Done!"
