#!/bin/bash
set -Eeuo pipefail # Better error handling

echo "========================================="
echo "       Interactive Deployment Script     "
echo "========================================="

# ----------------------------
# INTERACTIVE CONFIGURATION
# ----------------------------

# 1. Project Folder Name
read -p "Enter project folder name (created in $HOME/) [default: smartduuka]: " input_folder_name
FOLDER_NAME="${input_folder_name:-smartduuka}"
PROJECT_DIR="$HOME/$FOLDER_NAME"

# 2. Web Repository
read -p "Enter Web GitHub Repo (username/repo) [default: kimdigitary/smartduukanewfront]: " input_web_repo
WEB_REPO="${input_web_repo:-kimdigitary/smartduukanewfront}"
WEB_REPO="${WEB_REPO#https://github.com/}"
WEB_REPO="${WEB_REPO%.git}"
WEB_USER="${WEB_REPO%/*}" # Extracts username before the slash

# 3. Backend Repository
read -p "Enter Backend GitHub Repo (username/repo) [default: omodingmike/smartduuka2]: " input_backend_repo
BACKEND_REPO="${input_backend_repo:-omodingmike/smartduuka2}"
BACKEND_REPO="${BACKEND_REPO#https://github.com/}"
BACKEND_REPO="${BACKEND_REPO%.git}"
BACKEND_USER="${BACKEND_REPO%/*}"

# 4. Swap Size & Network
read -p "Enter Swap Size [default: 1G]: " input_swap_size
SWAP_SIZE="${input_swap_size:-1G}"
read -p "Enter Docker Network Name [default: smartduuka_network]: " input_network
NETWORK_NAME="${input_network:-smartduuka_network}"

# Derived variables mapped to our dynamic SSH aliases
WEB_REPO_URL="git@github-${WEB_USER}:${WEB_REPO}.git"
BACKEND_REPO_URL="git@github-${BACKEND_USER}:${BACKEND_REPO}.git"
WEB_DIR="$PROJECT_DIR/web"
BACKEND_DIR="$PROJECT_DIR/api"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

echo ""
log "🚀 Starting deployment to $PROJECT_DIR..."
echo ""

# ----------------------------
# 1. UNIQUE SSH KEY GENERATION
# ----------------------------
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

setup_ssh_key() {
  local repo_full_name=$1  # e.g., omodingmike/smartduuka2
  local repo_alias="${repo_full_name//\//_}" # Replaces / with _ for filename safety
  local key_path="$HOME/.ssh/id_ed25519_$repo_alias"
  local host_alias="github-$repo_alias"

  # 1. Generate Key only if it doesn't exist
  if [ ! -f "$key_path" ]; then
    log "🔑 Generating unique key for $repo_full_name..."
    ssh-keygen -t ed25519 -C "deploy-$repo_alias" -f "$key_path" -N ""
    eval "$(ssh-agent -s)" &>/dev/null
    ssh-add "$key_path" &>/dev/null
  else
    log "✅ SSH key for $repo_alias already exists. Skipping generation."
  fi

  # 2. Add to SSH Config only if not already present
  local ssh_config="$HOME/.ssh/config"
  if ! grep -qF "Host $host_alias" "$ssh_config" 2>/dev/null; then
    log "📝 Adding config entry for $host_alias..."
    cat <<EOF >> "$ssh_config"

# Unique key for $repo_full_name
Host $host_alias
    HostName github.com
    User git
    IdentityFile $key_path
    IdentitiesOnly yes
EOF
  fi
}

# Generate unique pairs for both
setup_ssh_key "$WEB_REPO"
setup_ssh_key "$BACKEND_REPO"

# Generate CI/CD key for the server
CICD_KEY_PATH="$HOME/.ssh/id_ed25519_cicd_deploy"
if [ ! -f "$CICD_KEY_PATH" ]; then
  ssh-keygen -t ed25519 -C "cicd-auto-deploy" -f "$CICD_KEY_PATH" -N ""
fi

# ----------------------------
# 3. SEPARATE KEY DISPLAY & NOTES
# ----------------------------
echo ""
echo "================================================================="
echo "                 GITHUB SETUP INSTRUCTIONS                       "
echo "================================================================="
echo "Each repository requires a UNIQUE Deploy Key to avoid the "
echo "'Key is already in use' error."
echo ""

# WEB REPO
WEB_ALIAS="${WEB_REPO//\//_}"
echo "-----------------------------------------------------------------"
echo " 1. WEB REPOSITORY KEYS (Repo: $WEB_REPO)"
echo "-----------------------------------------------------------------"
echo " NOTES: Go to GitHub -> $WEB_REPO -> Settings -> Deploy Keys -> Add."
echo ""
echo " 👇 [ WEB - PUBLIC KEY ] 👇"
cat "$HOME/.ssh/id_ed25519_${WEB_ALIAS}.pub"
echo ""
echo " 👇 [ WEB - PRIVATE KEY ] 👇"
cat "$HOME/.ssh/id_ed25519_${WEB_ALIAS}"
echo ""

# BACKEND REPO
BACKEND_ALIAS="${BACKEND_REPO//\//_}"
echo "-----------------------------------------------------------------"
echo " 2. BACKEND REPOSITORY KEYS (Repo: $BACKEND_REPO)"
echo "-----------------------------------------------------------------"
echo " NOTES: Go to GitHub -> $BACKEND_REPO -> Settings -> Deploy Keys -> Add."
echo " (This key is unique and will not conflict with the Web key)."
echo ""
echo " 👇 [ BACKEND - PUBLIC KEY ] 👇"
cat "$HOME/.ssh/id_ed25519_${BACKEND_ALIAS}.pub"
echo ""
echo " 👇 [ BACKEND - PRIVATE KEY ] 👇"
cat "$HOME/.ssh/id_ed25519_${BACKEND_ALIAS}"
echo ""

# GITHUB ACCOUNT
echo "-----------------------------------------------------------------"
echo " 3. GITHUB ACCOUNT PUBLIC KEY (Server-wide Access)"
echo "-----------------------------------------------------------------"
echo " NOTES: Go to GitHub User Settings -> SSH and GPG keys -> New SSH key."
echo ""
echo " 👇 [ GITHUB ACCOUNT - PUBLIC KEY ] 👇"
cat "${CICD_KEY_PATH}.pub"
echo ""

# CI/CD SECRET
echo "-----------------------------------------------------------------"
echo " 4. CI/CD PRIVATE KEY (GitHub Actions Secret)"
echo "-----------------------------------------------------------------"
echo " NOTES: In your repo Settings -> Secrets -> Actions -> New Secret."
echo " Name it 'SSH_PRIVATE_KEY'."
echo ""
echo " 👇 [ CI/CD - PRIVATE KEY ] 👇"
cat "${CICD_KEY_PATH}"
echo ""
echo "================================================================="
echo ""

read -p "Press [Enter] once all keys are added to GitHub..."

# ----------------------------
# 4. VERIFY SSH CONNECTIONS
# ----------------------------
log "🧪 Verifying GitHub SSH Connections..."
set +e
if ssh -T "git@github-${WEB_ALIAS}" 2>&1 | grep -q "successfully authenticated"; then
    log "✅ Web repo SSH auth successful."
fi

if ssh -T "git@github-${BACKEND_ALIAS}" 2>&1 | grep -q "successfully authenticated"; then
    log "✅ Backend repo SSH auth successful."
fi
set -e

# ----------------------------
# UPDATE SYSTEM & INSTALL TOOLS
# ----------------------------
log "📦 Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y curl git unzip software-properties-common gnupg lsb-release

# ----------------------------
# Add Swap Space (Idempotent)
# ----------------------------
if [ -f /swapfile ]; then
  log "✅ Swapfile already exists."
else
  log "➕ Creating ${SWAP_SIZE} swap space..."
  sudo fallocate -l "$SWAP_SIZE" /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  append_if_missing "/swapfile none swap" "/swapfile none swap sw 0 0" /etc/fstab
fi

# ----------------------------
# ENSURE DOCKER REPOSITORY IS ADDED
# ----------------------------
if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
  log "🔑 Adding official Docker repository..."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
else
  log "✅ Docker repository already configured."
fi

# ----------------------------
# INSTALL DOCKER ENGINE
# ----------------------------
if ! command -v docker &> /dev/null; then
  log "🐳 Installing Docker Engine..."
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io
else
  log "✅ Docker already installed."
fi

sudo systemctl enable docker --now

# ----------------------------
# ENSURE BUILDX IS INSTALLED
# ----------------------------
if ! docker buildx version &> /dev/null; then
  log "📦 Installing Docker Buildx plugin..."
  sudo apt-get update
  sudo apt-get install -y docker-buildx-plugin
else
  log "✅ Docker Buildx already installed."
fi

# ----------------------------
# FETCH & INSTALL LATEST DOCKER COMPOSE
# ----------------------------
log "🐳 Fetching the absolute latest Docker Compose V2..."
COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
COMPOSE_DEST="/usr/local/lib/docker/cli-plugins/docker-compose"
INSTALLED_VERSION=""
if [ -f "$COMPOSE_DEST" ]; then
  INSTALLED_VERSION=$(docker compose version --short 2>/dev/null || true)
fi

if [ "$INSTALLED_VERSION" != "${COMPOSE_VERSION#v}" ]; then
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  sudo curl -SL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-$(uname -m)" -o "$COMPOSE_DEST"
  sudo chmod +x "$COMPOSE_DEST"
  log "✅ Docker Compose updated to ${COMPOSE_VERSION}"
else
  log "✅ Docker Compose already at latest version (${COMPOSE_VERSION})."
fi

# ----------------------------
# SETUP NETWORK
# ----------------------------
if ! sudo docker network ls --format '{{.Name}}' | grep -wq "$NETWORK_NAME"; then
  log "🌐 Creating network '$NETWORK_NAME'..."
  sudo docker network create "$NETWORK_NAME"
else
  log "✅ Docker network '$NETWORK_NAME' already exists."
fi

# ----------------------------
# CLONE / UPDATE REPOS
# ----------------------------
mkdir -p "$PROJECT_DIR"

clone_or_pull() {
  local url=$1
  local dir=$2
  if [ ! -d "$dir/.git" ]; then
    log "📥 Cloning $url..."
    git clone "$url" "$dir"
  else
    log "🔄 Updating $dir..."
    cd "$dir" && git pull
  fi
}

clone_or_pull "$WEB_REPO_URL" "$WEB_DIR"
clone_or_pull "$BACKEND_REPO_URL" "$BACKEND_DIR"

# ----------------------------
# FIX PERMISSIONS & SYMLINKS
# ----------------------------
log "🔐 Fixing Laravel permissions..."
WRITABLE_DIRS=(
  "$BACKEND_DIR/storage"
  "$BACKEND_DIR/bootstrap/cache"
  "$BACKEND_DIR/public/media"
  "$BACKEND_DIR/public/static"
  "$BACKEND_DIR/.cache"
)

for DIR in "${WRITABLE_DIRS[@]}"; do
  mkdir -p "$DIR"
  sudo chown -R 33:33 "$DIR"
  sudo chmod -R 775 "$DIR"
done

log "🔗 Ensuring storage symlink..."
cd "$BACKEND_DIR"
if [ ! -L public/storage ] || [ "$(readlink public/storage)" != "../storage/app/public" ]; then
  rm -f public/storage
  ln -s ../storage/app/public public/storage
  log "✅ Symlink created."
else
  log "✅ Symlink already correct."
fi
cd "$PROJECT_DIR"

# ----------------------------
# DOCKER BUILD & START
# ----------------------------
log "🔨 Building and starting containers..."
sudo docker compose up -d --build --force-recreate --remove-orphans

# ----------------------------
# LARAVEL POST-DEPLOY
# ----------------------------
log "📦 Running Laravel optimizations..."
sudo docker compose exec -T api composer install --no-dev --optimize-autoloader
sudo docker compose exec -T api php artisan migrate --force
sudo docker compose exec -T api php artisan optimize:clear
sudo docker compose exec -T api php artisan optimize

log "🧹 Cleaning up old images..."
sudo docker image prune -f

log "✅ Deployment complete!"