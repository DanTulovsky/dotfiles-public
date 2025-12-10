#!/bin/bash
#
# setup_new.sh
#
# Sets up a new machine (macOS, Linux - Debian/Ubuntu/Fedora) with required tools and configurations.
#

set -e
set -o pipefail
shopt -s expand_aliases

# ==============================================================================
# Constants & Configuration
# ==============================================================================

# Core tools required on all systems
REQUIRED_COMMANDS=(
  git
  fzf
  keychain
  vim
  fish
)

# Core packages required on all systems
REQUIRED_PACKAGES=(
  htop
  btop
  npm
  golang
  rclone
  duf
  lsd
  ripgrep
)

# Linux General
LINUX_REQUIRED_COMMANDS=(
  ssh-askpass
)

# Fedora Specific
FEDORA_REQUIRED_PACKAGES=(
  make
  automake
  gcc
  gcc-c++
  kernel-devel
  zlib-devel
  readline-devel
  openssl-devel
  bzip2-devel
  libffi-devel
  sqlite-devel
  xz-devel
  pipx
  ranger
  gnupg
  curl
  direnv
  bind-utils
  openssh-askpass
  dnf-plugins-core
)

# Debian/Ubuntu Specific
DEBIAN_REQUIRED_PACKAGES=(
  snapd
)

UBUNTU_COMMON_PACKAGES=(
  build-essential
  zlib1g
  zlib1g-dev
  libreadline8
  libreadline-dev
  libssl-dev
  lzma
  bzip2
  libffi-dev
  libsqlite3-0
  libsqlite3-dev
  libbz2-dev
  liblzma-dev
  pipx
  ranger
  locales
  bzr
  apt-transport-https
  ca-certificates
  gnupg
  curl
  direnv
  bind9-utils
)

SNAP_REQUIRED_PACKAGES=()

# ==============================================================================
# Logging Helper Functions
# ==============================================================================

function log_info() {
  echo -e "\033[34m[INFO]\033[0m $*"
}

function log_success() {
  echo -e "\033[32m[OK]\033[0m $*"
}

function log_warn() {
  echo -e "\033[33m[WARN]\033[0m $*"
}

function log_error() {
  echo -e "\033[31m[ERROR]\033[0m $*" >&2
}

# ==============================================================================
# OS Detection Functions
# ==============================================================================

function is_linux() {
  uname -a | grep -i linux > /dev/null 2>&1
  return $?
}

function is_darwin() {
  uname -a | grep -i darwin > /dev/null 2>&1
  return $?
}

function is_debian() {
  [ -f /etc/debian_version ] || (uname -a | grep -i debian > /dev/null 2>&1)
  return $?
}

function is_ubuntu() {
  uname -a | grep -i ubuntu > /dev/null 2>&1
  return $?
}

function is_jammy() {
  uname -a | grep -i jammy > /dev/null 2>&1
  return $?
}

function is_fedora() {
  if [ -f /etc/os-release ]; then
    grep -qi "^ID=.*fedora" /etc/os-release
    return $?
  fi
  return 1
}

function is_arm_linux() {
  uname -m | grep -E -i "arm|aarch64" > /dev/null 2>&1
  return $?
}

function load_os_release() {
  if [[ -n ${OS_RELEASE_LOADED:-} ]]; then
    return
  fi
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_RELEASE_LOADED=1
  else
    OS_RELEASE_LOADED=0
  fi
}

function get_os_release_major_version() {
  load_os_release
  local version="${VERSION_ID:-}"
  if [[ ${version} =~ ^([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '0\n'
  fi
}

function get_os_release_minor_version() {
  load_os_release
  local version="${VERSION_ID:-}"
  if [[ ${version} =~ ^[0-9]+\.([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '0\n'
  fi
}

function get_os_release_codename() {
  load_os_release
  printf '%s\n' "${VERSION_CODENAME:-}"
}

# ==============================================================================
# Package Management Helper Functions
# ==============================================================================

# Install a package using the system's package manager
function install_package() {
  local package="$1"
  local fedora_package="${2:-$package}" # Optional mapping for Fedora

  if is_fedora; then
    log_info "Installing ${fedora_package} via dnf..."
    if ! sudo dnf install -y "${fedora_package}"; then
      log_warn "dnf failed to install ${fedora_package}"
      if command -v brew >/dev/null 2>&1; then
        log_info "Trying brew install ${package}..."
        brew install "${package}"
        return $?
      fi
      return 1
    fi
  elif is_linux; then
    log_info "Installing ${package} via apt..."
    if ! sudo apt install -y "${package}"; then
      log_warn "apt failed to install ${package}"
      if command -v brew >/dev/null 2>&1; then
        log_info "Trying brew install ${package}..."
        brew install "${package}"
        return $?
      fi
      return 1
    fi
  elif is_darwin; then
    log_info "Installing ${package} via brew..."
    if ! brew install "${package}"; then
      log_error "Failed to install ${package}"
      return 1
    fi
  else
    log_error "Unsupported OS for package installation"
    return 1
  fi
  log_success "Installed ${package}"
}

# Ensure a command exists, otherwise attempt to install it
function ensure_command() {
  local cmd="$1"
  local package="${2:-$cmd}" # Package name might differ from command name

  if command -v "${cmd}" >/dev/null 2>&1; then
    log_success "${cmd} is already available"
  else
    log_info "${cmd} not found. Installing..."
    install_package "${package}"
  fi
}

# ==============================================================================
# Specific Install Functions
# ==============================================================================

function lsp_install() {
  log_info "Installing Language Servers..."

  # Node-based LSPs
  sudo npm install -g n
  sudo n stable

  local npm_lsps=(
    vscode-langservers-extracted
    dockerfile-language-server-nodejs
    dot-language-server
    graphql-language-service-cli
    sql-language-server
    typescript
    typescript-language-server
    yaml-language-server@next
  )

  for lsp in "${npm_lsps[@]}"; do
      sudo npm i -g "${lsp}"
  done

  # Go tools
  go install golang.org/x/tools/gopls@latest
  go install github.com/go-delve/delve/cmd/dlv@latest
  go install golang.org/x/tools/cmd/goimports@latest

  # Terraform
  if command -v brew >/dev/null 2>&1; then
      brew install hashicorp/tap/terraform-ls
  else
      log_warn "brew not found, skipping terraform-ls. Install manually or enable brew."
  fi

  # Taplo (TOML)
  if command -v cargo >/dev/null 2>&1; then
    cargo install taplo-cli --locked --features lsp
  fi
}

function docker_linux_install() {
  if ! is_linux; then
    return
  fi
  log_info "Checking Docker installation for Linux..."
  if is_fedora; then
      sudo dnf -y install dnf-plugins-core
      sudo curl -o /etc/yum.repos.d/docker-ce.repo https://download.docker.com/linux/fedora/docker-ce.repo
      sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      sudo systemctl start docker
      sudo usermod -aG docker "$USER"
      return
  fi

  local dist=""
  if is_debian; then dist="debian"; fi
  if is_ubuntu; then dist="ubuntu"; fi

  if [ -z "${dist}" ]; then
    log_warn "Unsupported distribution for Docker install"
    return
  fi

  sudo apt-get update
  sudo apt-get install ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/"${dist}"/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  if [[ ! -e /etc/apt/sources.list.d/docker.list ]]; then
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${dist} \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
  else
    log_info "Docker repository already added"
  fi
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
}

function gcloud_linux_install() {
  if ! is_linux; then
    return
  fi

  if command -v gcloud >/dev/null 2>&1; then
    log_success "gcloud is already installed"
    return
  fi

  log_info "Installing gcloud..."
  if is_fedora; then
    sudo tee /etc/yum.repos.d/google-cloud-sdk.repo << EOM
[google-cloud-cli]
name=Google Cloud CLI
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOM
    sudo dnf install -y google-cloud-cli kubectl
    return
  fi

  curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
  sudo apt-get update && sudo apt-get install -y google-cloud-cli kubectl
}

function krew_install_plugins() {
  log_info "Installing Krew plugins..."
  (
    set -x; cd "$(mktemp -d)" &&
    OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
    ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
    KREW="krew-${OS}_${ARCH}" &&
    curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
    tar zxvf "${KREW}.tar.gz" &&
    ./"${KREW}" install krew
  )
  hash -r
  ~/.krew_plugins || log_warn "Failed to run .krew_plugins"
}

function install_lazygit() {
  if command -v lazygit >/dev/null 2>&1; then
    log_success "lazygit already installed"
    return
  fi

  log_info "Installing lazygit..."

  if is_darwin; then
    brew install lazygit
    return
  fi

  if is_fedora; then
    sudo dnf -y copr enable dejan/lazygit
    sudo dnf install -y lazygit
    return
  fi

  if ! is_linux; then
    log_warn "Skipping lazygit install: unsupported OS"
    return
  fi

  if is_debian; then
    local major
    local codename
    major="$(get_os_release_major_version)"
    codename="$(get_os_release_codename)"
    if [[ ${codename} == "sid" ]]; then
      sudo apt install -y lazygit
      return
    fi
    if [[ -n ${major} ]] && (( major >= 13 )); then
      sudo apt install -y lazygit
      return
    fi
  elif is_ubuntu; then
    local major
    local minor
    major="$(get_os_release_major_version)"
    minor="$(get_os_release_minor_version)"
    if [[ -n ${major} && -n ${minor} ]] && { (( major > 25 )) || (( major == 25 && minor >= 10 )); }; then
      sudo apt install -y lazygit
      return
    fi
  fi

  tmpdir="$(mktemp -d)"
  (
    set -e
    cd "${tmpdir}"
    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": *"v\K[^"]*')
    curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
    tar xf lazygit.tar.gz lazygit
    sudo install lazygit -D -t /usr/local/bin/
  )
  rm -rf "${tmpdir}"
}

function install_lazyjournal() {
  if command -v lazyjournal >/dev/null 2>&1; then
    log_success "lazyjournal already installed"
    return
  fi

  log_info "Installing lazyjournal..."

  if is_darwin; then
    brew install lazyjournal
    return
  fi

  if is_debian || is_ubuntu; then
    arch=$(test "$(uname -m)" = "aarch64" && echo "arm64" || echo "amd64")
    release_version=$(curl -L -sS -H 'Accept: application/json' https://github.com/Lifailon/lazyjournal/releases/latest | sed -e 's/.*"tag_name":"\([^"]*\)".*/\1/')
    curl -L -sS "https://github.com/Lifailon/lazyjournal/releases/download/${release_version}/lazyjournal-${release_version}-${arch}.deb" -o /tmp/lazyjournal.deb
    sudo apt install /tmp/lazyjournal.deb
    return
  fi

  # For other systems (Fedora), use the install script
  curl -sS https://raw.githubusercontent.com/Lifailon/lazyjournal/main/install.sh | bash
}

function install_cargo_binstall() {
  if ! command -v cargo-binstall >/dev/null 2>&1; then
    log_info "Installing cargo-binstall..."
    if command -v brew >/dev/null 2>&1; then
        brew install cargo-binstall
    else
        log_warn "Manual install of cargo-binstall required on Linux if brew is missing"
        # Optional: cargo install cargo-binstall
    fi
  else
    log_success "cargo-binstall already installed"
  fi
}

function system_update_linux() {
  if is_fedora; then
      sudo dnf group install -y "development-tools"
      sudo dnf update -y
  elif is_debian || is_ubuntu; then
      if [ -f /etc/apt/sources.list ]; then
        sudo sed -i -e 's/^# *deb-src/deb-src/g' /etc/apt/sources.list
      fi
      if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
         sudo sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
      fi
      sudo apt-get update
      sudo apt-get -y build-dep python3
  fi
}

function install_sk() {
  if ! command -v sk >/dev/null 2>&1; then
    log_info "Installing sk..."
    if command -v brew >/dev/null 2>&1; then
      brew install sk
    else
      log_warn "brew not found, cannot install sk"
    fi
  else
    log_success "sk already installed"
  fi
}

function install_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    log_info "Installing tmux..."
    if command -v brew >/dev/null 2>&1; then
      brew install tmux
    else
      log_warn "brew not found. Fallback to system package implementation: install_package"
      install_package "tmux"
    fi
  else
    log_success "tmux already installed"
  fi
}

function install_zellij() {
  if ! command -v zellij >/dev/null 2>&1; then
      log_info "Installing zellij..."
      cargo binstall -y zellij
  else
      log_success "zellij already installed"
  fi
}

function install_starship() {
  log_info "Installing starship..."
  if is_darwin; then
    brew install starship
  else
    if command -v starship >/dev/null 2>&1; then
      log_success "starship already installed"
    else
      curl -sS https://starship.rs/install.sh | sh -s -- -y
    fi
  fi
}

function install_atuin() {
  log_info "Installing atuin..."
  if command -v atuin >/dev/null 2>&1; then
    log_success "atuin already installed"
  else
    curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh
  fi
}

function install_pyenv() {
  log_info "Installing pyenv..."
  if is_darwin; then
    brew install pyenv pyenv-virtualenv
  else
    if [[ -d ~/.pyenv ]]; then
      log_success "pyenv already installed"
    else
      curl https://pyenv.run | bash
    fi
  fi
}

function install_python_version() {
  log_info "Installing python 3.12..."
  export PYENV_ROOT="$HOME/.pyenv"
  [[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
  if command -v pyenv >/dev/null 2>&1; then
      eval "$(pyenv init -)"
      pyenv install --skip-existing 3.12
  else
      log_error "pyenv not found, skipping python 3.12 install"
  fi
}

function install_fonts_and_ui() {
  if is_darwin; then
    brew install font-meslo-lg-nerd-font

    # VSCode settings
    defaults write com.microsoft.VSCode ApplePressAndHoldEnabled -bool false
    defaults write com.microsoft.VSCodeInsiders ApplePressAndHoldEnabled -bool false
    defaults write com.vscodium ApplePressAndHoldEnabled -bool false
    defaults write com.microsoft.VSCodeExploration ApplePressAndHoldEnabled -bool false
    defaults delete -g ApplePressAndHoldEnabled || true
  else
    log_info "Install fonts manually from: https://github.com/romkatv/powerlevel10k?tab=readme-ov-file#fonts"
  fi
}

function install_tpm() {
  touch "$HOME"/.tmux.conf.local
  log_info "Installing tmux plugin manager..."
  mkdir -p "$HOME/.tmux/plugins"
  if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
    git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
  else
    log_success "tmux plugin manager already installed"
  fi
}

function install_orbstack() {
  if is_darwin; then
      if ! command -v orb; then
        brew install orbstack
      fi
  fi
}

# ==============================================================================
# Main Execution Logic
# ==============================================================================

function main() {
    log_info "Starting Setup..."

    # Initial Mac Setup
    if is_darwin; then
      if ! command -v brew > /dev/null 2>&1; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        brew install curl wget git fzf keychain tmux vim fish direnv
      fi
    fi

    # Install Homebrew on Linux if missing
    if ! command -v brew >/dev/null 2>&1; then
         if is_linux; then
            log_info "Installing Homebrew for Linux..."
             /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
             eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
         fi
    fi

    # --- Install Required Commands ---
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        ensure_command "${cmd}"
    done

    # --- Install Required Packages ---
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if is_fedora && [[ "${pkg}" == "golang" ]]; then
             install_package "golang"
             continue
        fi

        if is_linux && [[ "${pkg}" == "golang" ]]; then
            if is_jammy; then
                sudo apt install snapd
                sudo snap install --classic --channel=1.22/stable go
                continue
            fi
        fi

        install_package "${pkg}"
    done

    # --- Linux Specifics ---
    if is_linux; then
        for cmd in "${LINUX_REQUIRED_COMMANDS[@]}"; do
             if is_fedora && [[ "${cmd}" == "ssh-askpass" ]]; then
                 install_package "openssh-askpass"
             else
                 ensure_command "${cmd}"
             fi
        done

        system_update_linux # Build deps etc

        if is_fedora; then
            for pkg in "${FEDORA_REQUIRED_PACKAGES[@]}"; do
                install_package "${pkg}"
            done
        elif is_debian || is_ubuntu; then
             for pkg in "${UBUNTU_COMMON_PACKAGES[@]}"; do
                 install_package "${pkg}"
             done
             sudo locale-gen en_US.UTF-8

             if is_debian; then
                 for pkg in "${DEBIAN_REQUIRED_PACKAGES[@]}"; do
                     install_package "${pkg}"
                 done
                 # Snaps
                 for pkg in "${SNAP_REQUIRED_PACKAGES[@]}"; do
                    sudo snap install "${pkg}" --classic
                 done
             fi
        fi

        # Configure Homebrew apps on Linux if needed
        # (Original script had checks for ~/.homebrew_apps on Darwin mainly)
    fi

    # --- Custom Installers ---
    install_lazygit
    install_lazyjournal

    # --- Shell Setup ---
    # Set fish as default (Note: This might exit the script if it changes shell!)
    if ! echo "${SHELL}" | grep fish >/dev/null 2>&1; then
      log_info "Setting default shell to fish..."
      if command -v fish >/dev/null 2>&1; then
        if is_linux; then
          sudo usermod -s "$(which fish)" "$USER"
        elif is_darwin; then
          sudo dscl . -create "/Users/$USER" UserShell "$(which fish)"
        fi
        log_warn "Default shell changed to fish. Please logout and login again for this to take effect."
        # Continue execution
      else
        log_error "fish is not installed"
        exit 1
      fi
    else
      log_success "fish is already the default shell"
    fi

    # --- Cargo / Rust ---
    log_info "Instaling/updating Rust..."
    if ! command -v cargo; then
      curl https://sh.rustup.rs -sSf | sh -s -- -y
      export PATH="$HOME/.cargo/bin:$PATH"
    fi

    log_info "Installing dust..."
    if ! command -v dust >/dev/null 2>&1; then
      cargo install du-dust
    else
      log_success "dust already installed"
    fi

    # --- SSH Keys ---
    local git_identity_file="${HOME}/.ssh/identity.git"
    if [ ! -f "${git_identity_file}" ]; then
      log_info "Generating ssh key for github into ${git_identity_file}"
      ssh-keygen -f "${git_identity_file}"
      echo "Add this key to github before continuing: https://github.com/settings/keys"
      echo ""
      cat "${git_identity_file}".pub
      echo ""
      read -rp "Press Enter once you have added the key to GitHub to continue..."
    fi

    # --- Dotfiles Configuration ---
    log_info "Configuring dotfiles..."

    if ! grep ".cfg" "$HOME/.gitignore" >/dev/null 2>&1; then
      echo ".cfg" >> "$HOME/.gitignore"
    fi

    log_info "Starting ssh agent..."
    keychain --nogui ~/.ssh/identity.git
    # shellcheck disable=SC1090
    if [ -f ~/.keychain/"$(hostname)"-sh ]; then
        source ~/.keychain/"$(hostname)"-sh
    fi

    function config() {
      git --git-dir="$HOME/.cfg/" --work-tree="$HOME" "$@"
    }

    log_info "Cloning dotfiles..."
    rm -rf "$HOME"/.cfg
    git clone --bare git@github.com:DanTulovsky/dotfiles-config.git "$HOME"/.cfg
    config reset --hard HEAD
    config config --local status.showUntrackedFiles no

    install_pyenv
    install_starship
    install_atuin
    install_python_version

    install_cargo_binstall
    install_sk
    install_tmux
    install_zellij

    docker_linux_install
    gcloud_linux_install
    install_orbstack
    krew_install_plugins || true
    install_fonts_and_ui
    install_tpm
    lsp_install
    log_success "Setup Complete!"
}

main "$@"
