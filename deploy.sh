#!/bin/bash
set -Eeuo pipefail # Better error handling

echo "========================================="
echo "       Interactive Deployment Script     "
echo "========================================="

# ----------------------------
# HELPER FUNCTIONS
# ----------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

append_if_missing() {
  local search_string="$1"
  local append_string="$2"
  local target_file="$3"
  if ! grep -qF "$search_string" "$target_file" 2>/dev/null; then
    echo "$append_string" | sudo tee -a "$target_file" > /dev/null
  fi
}

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
WEB_USER="${WEB_REPO%/*}"

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

# Derived variables
WEB_REPO_URL="git@github-${WEB_USER}:${WEB_REPO}.git"
BACKEND_REPO_URL="git@github-${BACKEND_USER}:${BACKEND_REPO}.git"
WEB_DIR="$PROJECT_DIR/web"
BACKEND_DIR="$PROJECT_DIR/api"

echo ""
log "🚀 Starting deployment to $PROJECT_DIR..."
echo ""

# ----------------------------
# 1. UNIQUE SSH KEY GENERATION (VPS -> GITHUB)
# ----------------------------
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

setup_ssh_key() {
  local repo_full_name=$1
  local repo_alias="${repo_full_name//\//_}"
  local key_path="$HOME/.ssh/id_ed25519_$repo_alias"
  local host_alias="github-$repo_alias"

  if [ ! -f "$key_path" ]; then
    log "🔑 Generating unique key for $repo_full_name..."
    ssh-keygen -t ed25519 -C "deploy-$repo_alias" -f "$key_path" -N ""
    eval "$(ssh-agent -s)" &>/dev/null
    ssh-add "$key_path" &>/dev/null
  else
    log "✅ SSH key for $repo_alias already exists."
  fi

  local ssh_config="$HOME/.ssh/config"
  if ! grep -qF "Host $host_alias" "$ssh_config" 2>/dev/null; then
    log "📝 Adding config entry for $host_alias..."
    cat <<EOF >> "$ssh_config"

Host $host_alias
    HostName github.com
    User git
    IdentityFile $key_path
    IdentitiesOnly yes
EOF
  fi
}

setup_ssh_key "$WEB_REPO"
setup_ssh_key "$BACKEND_REPO"

# ----------------------------
# 2. CI/CD KEY GENERATION (GITHUB -> VPS)
# ----------------------------
CICD_KEY_PATH="$HOME/.ssh/id_ed25519_cicd_deploy"
if [ ! -f "$CICD_KEY_PATH" ]; then
  log "🔑 Generating CI/CD key for GitHub Actions..."
  ssh-keygen -t ed25519 -C "cicd-auto-deploy" -f "$CICD_KEY_PATH" -N ""
fi

# IMPORTANT: Authorize the CI/CD key so GitHub Actions can actually log in
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
if ! grep -qF "$(cat "${CICD_KEY_PATH}.pub")" "$HOME/.ssh/authorized_keys"; then
  log "🔐 Authorizing CI/CD key in authorized_keys..."
  cat "${CICD_KEY_PATH}.pub" >> "$HOME/.ssh/authorized_keys"
fi

# ----------------------------
# 3. SEPARATE KEY DISPLAY & NOTES
# ----------------------------
WEB_ALIAS="${WEB_REPO//\//_}"
BACKEND_ALIAS="${BACKEND_REPO//\//_}"

echo ""
echo "================================================================="
echo "                 GITHUB SETUP INSTRUCTIONS                       "
echo "================================================================="
echo " 1. WEB REPO ($WEB_REPO) -> Settings -> Deploy Keys"
cat "$HOME/.ssh/id_ed25519_${WEB_ALIAS}.pub"
echo "-----------------------------------------------------------------"
echo " 2. BACKEND REPO ($BACKEND_REPO) -> Settings -> Deploy Keys"
cat "$HOME/.ssh/id_ed25519_${BACKEND_ALIAS}.pub"
echo "-----------------------------------------------------------------"
echo " 3. ADD TO BOTH REPOSITORIES -> Settings -> Secrets and variables -> Actions"
echo " Create a new repository secret named 'DEPLOY_KEY' and paste this:"
cat "${CICD_KEY_PATH}"
echo "================================================================="
echo ""

read -p "Press [Enter] once all keys are added to GitHub..."

# ----------------------------
# 4. VERIFY SSH CONNECTIONS
# ----------------------------
log "🧪 Verifying GitHub SSH Connections..."
ssh-keyscan -H github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
set +e
ssh -T "git@github-${WEB_ALIAS}" 2>&1 | grep -q "successfully authenticated" && log "✅ Web repo SSH auth successful."
ssh -T "git@github-${BACKEND_ALIAS}" 2>&1 | grep -q "successfully authenticated" && log "✅ Backend repo SSH auth successful."
set -e

# ----------------------------
# UPDATE SYSTEM & INSTALL TOOLS
# ----------------------------
log "📦 Updating system packages..."
sudo apt-get update && sudo apt-get install -y curl git unzip software-properties-common gnupg lsb-release

# ----------------------------
# SWAP SPACE
# ----------------------------
if [ ! -f /swapfile ]; then
  log "➕ Creating ${SWAP_SIZE} swap space..."
  sudo fallocate -l "$SWAP_SIZE" /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  append_if_missing "/swapfile none swap" "/swapfile none swap sw 0 0" /etc/fstab
fi

# ----------------------------
# DOCKER INSTALLATION
# ----------------------------
if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
  log "🔑 Adding official Docker repository..."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
fi

if ! command -v docker &> /dev/null; then
  log "🐳 Installing Docker Engine..."
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable docker --now
fi

# ----------------------------
# SETUP NETWORK & REPOS
# ----------------------------
sudo docker network ls --format '{{.Name}}' | grep -wq "$NETWORK_NAME" || sudo docker network create "$NETWORK_NAME"

mkdir -p "$PROJECT_DIR"
clone_or_pull() {
  local repo_url=$1
  local target_dir=$2

  if [ ! -d "$target_dir/.git" ]; then
    log "📥 Cloning $repo_url..."
    git clone "$repo_url" "$target_dir"
  else
    log "🔄 Updating $target_dir..."
    cd "$target_dir"
    # Force the remote URL to match the SSH alias before pulling
    git remote set-url origin "$repo_url"
    git pull
  fi
}

clone_or_pull "$WEB_REPO_URL" "$WEB_DIR"
clone_or_pull "$BACKEND_REPO_URL" "$BACKEND_DIR"

# ----------------------------
# PERMISSIONS
# ----------------------------
log "🔐 Fixing Laravel permissions..."
for DIR in storage bootstrap/cache public/media public/static .cache; do
  mkdir -p "$BACKEND_DIR/$DIR"
  sudo chown -R 33:33 "$BACKEND_DIR/$DIR"
  sudo chmod -R 775 "$BACKEND_DIR/$DIR"
done

cd "$BACKEND_DIR"
if [ ! -L public/storage ]; then
  ln -s ../storage/app/public public/storage
fi

# ----------------------------
# DOCKER BUILD & START
# ----------------------------
cd "$PROJECT_DIR"
log "🔨 Building and starting containers..."
sudo docker compose up -d --build --force-recreate --remove-orphans

log "📦 Running Laravel optimizations..."
sudo docker compose exec -T api composer install --no-dev --optimize-autoloader
sudo docker compose exec -T api php artisan migrate --force
sudo docker compose exec -T api php artisan optimize:clear
sudo docker compose exec -T api php artisan optimize
sudo docker image prune -f

# ----------------------------
# GENERATE CI/CD AUTOMATION SCRIPTS
# ----------------------------
log "📝 Generating CI/CD automated deployment scripts..."

# Generate Backend Deployment Script
cat << EOF > "$HOME/update_api.sh"
#!/bin/bash
set -Eeuo pipefail
echo "🚀 Starting Backend CI/CD Deployment..."
cd "$BACKEND_DIR"
git pull
cd "$PROJECT_DIR"
sudo docker compose build api
sudo docker compose up -d --no-deps api
sudo docker compose exec -T api composer install --no-dev --optimize-autoloader
sudo docker compose exec -T api php artisan migrate --force
sudo docker compose exec -T api php artisan optimize:clear
sudo docker compose exec -T api php artisan optimize
echo "✅ Backend updated successfully!"
EOF
chmod +x "$HOME/update_api.sh"

# Generate Web Deployment Script
cat << EOF > "$HOME/update_web.sh"
#!/bin/bash
set -Eeuo pipefail
echo "🚀 Starting Web CI/CD Deployment..."
cd "$WEB_DIR"
git pull
cd "$PROJECT_DIR"
sudo docker compose build web
sudo docker compose up -d --no-deps web
echo "✅ Web updated successfully!"
EOF
chmod +x "$HOME/update_web.sh"

log "✅ Full deployment complete! CI/CD scripts are ready."