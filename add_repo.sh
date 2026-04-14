#!/bin/bash
set -Eeuo pipefail

echo "========================================="
echo "       Add New Repository Script         "
echo "========================================="

# ----------------------------
# HELPER FUNCTIONS
# ----------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

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
REPO="${REPO%.git}"

# 3. Docker Network
read -p "Enter Docker Network Name [default: my_network]: " input_network
NETWORK_NAME="${input_network:-smartduuka_network}"

# ----------------------------
# DERIVED VARIABLES
# ----------------------------
REPO_ALIAS="${REPO//\//_}"
REPO_URL="git@github-${REPO_ALIAS}:${REPO}.git"

echo ""
log "🚀 Setting up $REPO at $TARGET_DIR..."
echo ""

# ----------------------------
# 1. SSH KEY GENERATION
# ----------------------------
KEY_PATH="$HOME/.ssh/id_ed25519_$REPO_ALIAS"
HOST_ALIAS="github-$REPO_ALIAS"

if [ ! -f "$KEY_PATH" ]; then
  log "🔑 Generating unique SSH key for $REPO..."
  ssh-keygen -t ed25519 -C "deploy-$REPO_ALIAS" -f "$KEY_PATH" -N ""
  eval "$(ssh-agent -s)" &>/dev/null
  ssh-add "$KEY_PATH" &>/dev/null
else
  log "✅ SSH key for $REPO_ALIAS already exists."
fi

# Update SSH Config
SSH_CONFIG="$HOME/.ssh/config"
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

# ----------------------------
# 2. GITHUB SETUP INSTRUCTIONS (BEFORE CLONING)
# ----------------------------
echo ""
echo "================================================================="
echo "                 GITHUB SETUP INSTRUCTIONS                       "
echo "================================================================="
echo " 1. Go to your repository: https://github.com/$REPO/settings/keys"
echo " 2. Click 'Add deploy key'"
echo " 3. Give it a title (e.g., 'VPS Deploy Key') and paste this exact key:"
echo "-----------------------------------------------------------------"
cat "${KEY_PATH}.pub"
echo "-----------------------------------------------------------------"
echo ""
read -p "Press [Enter] once the key has been added to GitHub..."
echo ""

# ----------------------------
# 3. VERIFY CONNECTION & CLONE
# ----------------------------
log "🧪 Verifying GitHub SSH Connection..."
ssh-keyscan -H github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
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
echo " ssh deploy@your-server-ip \"$UPDATE_SCRIPT\""
echo "================================================================="
echo ""
log "✅ Done!"