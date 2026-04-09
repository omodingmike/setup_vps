#!/bin/bash
set -Eeuo pipefail # Better error handling

echo "========================================="
echo "       Interactive Deployment Script     "
echo "========================================="

# ----------------------------
# INTERACTIVE CONFIGURATION
# ----------------------------

# 1. Project Folder Name
read -p "Enter project folder name (created in $HOME/) [default: myapp]: " input_folder_name
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

# 4. CI/CD Auto Deploy Key (Optional)
read -p "Paste public key for GitHub Actions Auto-Deploy (Press Enter to skip): " CI_CD_KEY

# 5. Swap Size & Network
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
# 1. SSH KEY GENERATION & CONFIG
# ----------------------------
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

setup_ssh_key() {
  local gh_user=$1
  local key_path="$HOME/.ssh/id_ed25519_$gh_user"
  local host_alias="github-$gh_user"

  if [ ! -f "$key_path" ]; then
    log "🔑 Generating SSH key for GitHub user: $gh_user..."
    ssh-keygen -t ed25519 -C "deploy-$gh_user" -f "$key_path" -N ""
    # Ensure ssh-agent is running and add key
    eval "$(ssh-agent -s)" &>/dev/null
    ssh-add "$key_path" &>/dev/null
  else
    log "✅ SSH key for $gh_user already exists."
  fi

  local ssh_config="$HOME/.ssh/config"
  touch "$ssh_config"
  if ! grep -q "Host $host_alias" "$ssh_config"; then
    log "📝 Adding SSH config alias for $host_alias..."
    cat <<EOF >> "$ssh_config"

# Account for $gh_user
Host $host_alias
    HostName github.com
    User git
    IdentityFile $key_path
    IdentitiesOnly yes
EOF
  fi
}

setup_ssh_key "$WEB_USER"
setup_ssh_key "$BACKEND_USER"

# Handle Optional CI/CD Auth Key
if [ -n "$CI_CD_KEY" ]; then
  log "🔐 Adding CI/CD Auto-Deploy Key to authorized_keys..."
  echo "$CI_CD_KEY" >> "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
fi

# ----------------------------
# 2. PAUSE FOR GITHUB SETUP
# ----------------------------
echo ""
echo "================================================================="
echo "⚠️  ACTION REQUIRED: ADD DEPLOY KEYS TO GITHUB ⚠️"
echo "================================================================="
echo "Please copy the following keys and add them to the 'Deploy Keys'"
echo "section of your GitHub repositories (or your account SSH keys)."
echo ""

echo "🔑 Key for $WEB_USER (Web Repo):"
cat "$HOME/.ssh/id_ed25519_${WEB_USER}.pub"
echo ""

if [ "$WEB_USER" != "$BACKEND_USER" ]; then
  echo "🔑 Key for $BACKEND_USER (Backend Repo):"
  cat "$HOME/.ssh/id_ed25519_${BACKEND_USER}.pub"
  echo ""
fi

read -p "Press [Enter] ONLY AFTER you have added these keys to GitHub..."

# ----------------------------
# 3. VERIFY SSH CONNECTIONS
# ----------------------------
log "🧪 Verifying GitHub SSH Connections..."
# set +e is needed here because ssh -T to github always exits with code 1, which trips pipefail
set +e
if ssh -T "git@github-${WEB_USER}" 2>&1 | grep -q "successfully authenticated"; then
    log "✅ Web repo SSH auth successful."
else
    log "⚠️ Warning: Web repo SSH auth failed. Git clone might fail."
fi

if ssh -T "git@github-${BACKEND_USER}" 2>&1 | grep -q "successfully authenticated"; then
    log "✅ Backend repo SSH auth successful."
else
    log "⚠️ Warning: Backend repo SSH auth failed. Git clone might fail."
fi
set -e # Re-enable strict error handling

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
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
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
fi

# ----------------------------
# INSTALL DOCKER ENGINE
# ----------------------------
if ! command -v docker &> /dev/null; then
  log "🐳 Installing Docker Engine..."
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io
fi

sudo systemctl enable docker --now

# ----------------------------
# ENSURE BUILDX IS INSTALLED
# ----------------------------
if ! docker buildx version &> /dev/null; then
  log "📦 Installing Docker Buildx plugin..."
  sudo apt-get update
  sudo apt-get install -y docker-buildx-plugin
fi

# ----------------------------
# FETCH & INSTALL LATEST DOCKER COMPOSE
# ----------------------------
log "🐳 Fetching the absolute latest Docker Compose V2..."
COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-$(uname -m)" -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
log "✅ Docker Compose dynamically updated to ${COMPOSE_VERSION}"

# ----------------------------
# SETUP NETWORK
# ----------------------------
if ! sudo docker network ls --format '{{.Name}}' | grep -wq "$NETWORK_NAME"; then
  log "🌐 Creating network '$NETWORK_NAME'..."
  sudo docker network create "$NETWORK_NAME"
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
rm -f public/storage
ln -s ../storage/app/public public/storage
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