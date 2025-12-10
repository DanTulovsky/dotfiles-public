#!/bin/bash
#
# setup_new.sh
#
# Sets up a new machine (macOS, Linux - Debian/Ubuntu/Fedora) with required tools and configurations.
#

set -e
set -o pipefail
function install_homebrew() {
    # Initial Mac Setup
    if is_darwin; then
      if ! command -v brew > /dev/null 2>&1; then
        log_task_start "Installing Homebrew"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if execute brew install curl wget git fzf keychain tmux vim fish direnv; then
            log_task_success
        else
            log_task_fail
        fi
      fi
    fi

    # Install Homebrew on Linux if missing
    if ! command -v brew >/dev/null 2>&1; then
         if is_linux; then
            log_task_start "Installing Homebrew for Linux"
             /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
             eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
             log_task_success
         fi
    fi
}

function install_core_tools() {
    # --- Install Required Commands ---
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        ensure_command "${cmd}"
    done
}

function install_core_packages() {
    # --- Install Required Packages ---
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if is_fedora && [[ "${pkg}" == "golang" ]]; then
             install_package "golang"
             continue
        fi

        if is_linux && [[ "${pkg}" == "golang" ]]; then
            if is_jammy; then
                execute sudo apt install snapd
                execute sudo snap install --classic --channel=1.22/stable go
                continue
            fi
        fi

        install_package "${pkg}"
    done
}

function install_linux_basics() {
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
}

function setup_shell() {
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
}

function install_rust() {
    # --- Cargo / Rust ---
    log_task_start "Instaling/updating Rust"
    if ! command -v cargo; then
      if curl https://sh.rustup.rs -sSf | sh -s -- -y >/dev/null 2>&1; then
          export PATH="$HOME/.cargo/bin:$PATH"
          log_task_success
      else
          log_task_fail
      fi
    else
        log_task_success
    fi
}

function install_dust() {
    log_task_start "Installing dust"
    if ! command -v dust >/dev/null 2>&1; then
      if execute cargo install du-dust; then
        log_task_success
      else
        log_task_fail
      fi
    else
      log_task_success
      log_success "dust already installed"
    fi
}

function setup_ssh_keys() {
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
}

function setup_dotfiles() {
    # --- Dotfiles Configuration ---
    log_task_start "Configuring dotfiles"

    if ! grep ".cfg" "$HOME/.gitignore" >/dev/null 2>&1; then
      execute echo ".cfg" >> "$HOME/.gitignore"
    fi

    log_info "Starting ssh agent..."
    keychain --nogui ~/.ssh/identity.git
    # shellcheck disable=SC1090
    if [ -f ~/.keychain/"$(hostname)"-sh ]; then
        source ~/.keychain/"$(hostname)"-sh
    fi

    # helper for config command
    function config() {
      git --git-dir="$HOME/.cfg/" --work-tree="$HOME" "$@"
    }

    execute rm -rf "$HOME"/.cfg
    if execute git clone --bare git@github.com:DanTulovsky/dotfiles-config.git "$HOME"/.cfg; then
        execute config reset --hard HEAD
        execute config config --local status.showUntrackedFiles no
        log_task_success
    else
        log_task_fail
    fi
}

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

function log_task_start() {
  echo -ne "\033[34m[INFO]\033[0m $*... "
}

function log_task_success() {
  echo -e "\033[32m[OK]\033[0m"
}

function log_task_fail() {
  echo -e "\033[31m[FAILED]\033[0m"
}

# ==============================================================================
# Execution Helpers
# ==============================================================================

function execute() {
  local temp_log
  temp_log=$(mktemp)

  # Run command in background
  "$@" > "$temp_log" 2>&1 &
  local pid=$!

  # Spinner loop
  local delay=0.1
  local spinstr='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b\b\b\b"
  done

  wait "$pid"
  local exit_code=$?

  if [ $exit_code -eq 0 ]; then
    rm "$temp_log"
    return 0
  else
    # If failed, we need to print newline to break from the "Installing..." line if it was used
    # However, execute can be used without log_task_start.
    # But usually it is used in context.
    # We will assume caller handles success/fail OK marker, but we need to print error details.

    # Clean up the spinner line artifact if any (handled by backspaces, but cursor is at pos)
    printf "       \b\b\b\b\b\b\b"

    rm "$temp_log"
    # Return 1, caller will handle printing [FAILED] and then maybe we print the log?
    # Better to just return output here on failure?
    # No, caller expects us to handle error logging usually?
    # Current contract: execute prints error log.

    # We need a newline because log_error expects to start on new line
    echo ""
    log_error "Command failed: $*"
    cat "$temp_log" >&2
    return $exit_code
  fi
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

function is_package_installed() {
  local package="$1"
  if is_darwin; then
    brew list --formula "$package" >/dev/null 2>&1 || brew list --cask "$package" >/dev/null 2>&1
  elif is_fedora; then
    rpm -q "$package" >/dev/null 2>&1
  elif is_linux; then
    dpkg -s "$package" >/dev/null 2>&1
  fi
}

# Install a package using the system's package manager
function install_package() {
  local package="$1"
  local fedora_package="${2:-$package}" # Optional mapping for Fedora

  if is_package_installed "${package}"; then
     log_success "${package} is already installed"
     return 0
  fi

  if is_fedora; then
    log_task_start "Installing ${fedora_package} via dnf"
    if ! execute sudo dnf install -y "${fedora_package}"; then
      log_task_fail
      log_warn "dnf failed to install ${fedora_package}"
      if command -v brew >/dev/null 2>&1; then
        log_task_start "Trying brew install ${package}"
        if execute brew install "${package}"; then
            log_task_success
            return 0
        else
            log_task_fail
            return 1
        fi
      fi
      return 1
    fi
    log_task_success
  elif is_linux; then
    log_task_start "Installing ${package} via apt"
    if ! execute sudo apt install -y "${package}"; then
      log_task_fail
      log_warn "apt failed to install ${package}"
      if command -v brew >/dev/null 2>&1; then
        log_task_start "Trying brew install ${package}"
        if execute brew install "${package}"; then
            log_task_success
            return 0
        else
            log_task_fail
            return 1
        fi
      fi
      return 1
    fi
    log_task_success
  elif is_darwin; then
    log_task_start "Installing ${package} via brew"
    if ! execute brew install "${package}"; then
      log_task_fail
      log_error "Failed to install ${package}"
      return 1
    fi
    log_task_success
  else
    log_error "Unsupported OS for package installation"
    return 1
  fi
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
  execute sudo npm install -g n
  execute sudo n stable

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
      execute sudo npm i -g "${lsp}"
  done

  # Go tools
  execute go install golang.org/x/tools/gopls@latest
  execute go install github.com/go-delve/delve/cmd/dlv@latest
  execute go install golang.org/x/tools/cmd/goimports@latest

  if command -v brew >/dev/null 2>&1; then
      log_task_start "Installing terraform-ls via brew"
      if execute brew install hashicorp/tap/terraform-ls; then
        log_task_success
      else
        log_task_fail
      fi
  else
      log_warn "brew not found, skipping terraform-ls. Install manually or enable brew."
  fi

  # Taplo (TOML)
  if command -v cargo >/dev/null 2>&1; then
    execute cargo install taplo-cli --locked --features lsp
  fi
}

function docker_linux_install() {
  if ! is_linux; then
    return
  fi
  log_task_start "Checking Docker installation for Linux"
  if is_fedora; then
      if execute sudo dnf -y install dnf-plugins-core \
        && execute sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo \
        && execute sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
            log_task_success
      else
            log_task_fail
      fi
      log_task_start "Adding user to docker group"
      execute sudo usermod -aG docker "$USER" && log_task_success || log_task_fail
      return
  fi

  if command -v docker >/dev/null 2>&1; then
    log_task_success
    log_success "Docker already installed"
    return
  fi

  execute sudo apt-get update
  execute sudo apt-get install ca-certificates curl
  execute sudo install -m 0755 -d /etc/apt/keyrings
  execute sudo curl -fsSL https://download.docker.com/linux/"${dist}"/gpg -o /etc/apt/keyrings/docker.asc
  execute sudo chmod a+r /etc/apt/keyrings/docker.asc

  if [[ ! -e /etc/apt/sources.list.d/docker.list ]]; then
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${dist} \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    execute sudo apt-get update
  else
    true
  fi

  log_task_start "Installing Docker packages"
  if execute sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    log_task_success
  else
    log_task_fail
  fi
  execute sudo usermod -aG docker "$USER"
}

function gcloud_linux_install() {
  if ! is_linux; then
    return
  fi

  if command -v gcloud >/dev/null 2>&1; then
    log_success "gcloud is already installed"
    return
  fi

  log_task_start "Installing Google Cloud SDK"
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
    if execute sudo dnf install -y google-cloud-cli kubectl; then
      log_task_success
    else
      log_task_fail
    fi
    return
  fi

  execute curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
  if execute sudo apt-get update && execute sudo apt-get install -y google-cloud-cli kubectl; then
    log_task_success
  else
    log_task_fail
  fi
}

function krew_install_plugins() {
  log_task_start "Installing Krew plugins"
  if (
    cd "$(mktemp -d)" &&
    OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
    ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
    KREW="krew-${OS}_${ARCH}" &&
    execute curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
    execute tar zxf "${KREW}.tar.gz" &&
    execute ./"${KREW}" install krew
  ) && {
      execute hash -r
      execute ~/.krew_plugins
  }; then
    log_task_success
  else
    log_task_fail
  fi
}

function install_lazygit() {
  if command -v lazygit >/dev/null 2>&1; then
    log_success "lazygit already installed"
    return
  fi

  log_task_start "Installing lazygit"

  if is_darwin; then
    if execute brew install lazygit; then
        log_task_success
    else
        log_task_fail
    fi
    return
  fi

  if is_fedora; then
    execute sudo dnf -y copr enable dejan/lazygit
    if execute sudo dnf install -y lazygit; then
        log_task_success
    else
        log_task_fail
    fi
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
      execute sudo apt install -y lazygit
      return
    fi
    if [[ -n ${major} ]] && (( major >= 13 )); then
      execute sudo apt install -y lazygit
      return
    fi
  elif is_ubuntu; then
    local major
    local minor
    major="$(get_os_release_major_version)"
    minor="$(get_os_release_minor_version)"
    if [[ -n ${major} && -n ${minor} ]] && { (( major > 25 )) || (( major == 25 && minor >= 10 )); }; then
      execute sudo apt install -y lazygit
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
    execute sudo apt install /tmp/lazyjournal.deb
    return
  fi

  # For other systems (Fedora), use the install script
  curl -sS https://raw.githubusercontent.com/Lifailon/lazyjournal/main/install.sh | bash
}

function install_cargo_binstall() {
  if ! command -v cargo-binstall >/dev/null 2>&1; then
    log_task_start "Installing cargo-binstall"
    if command -v brew >/dev/null 2>&1; then
        if execute brew install cargo-binstall; then
            log_task_success
        else
            log_task_fail
        fi
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
      execute sudo apt-get update
      execute sudo apt-get -y build-dep python3
  fi
}

function install_sk() {
  if ! command -v sk >/dev/null 2>&1; then
    log_task_start "Installing sk"
    if command -v brew >/dev/null 2>&1; then
      if execute brew install sk; then
          log_task_success
      else
          log_task_fail
      fi
    else
      log_task_fail
      log_warn "brew not found, cannot install sk"
    fi
  else
    log_success "sk already installed"
  fi
}

function install_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    log_task_start "Installing tmux"
    if command -v brew >/dev/null 2>&1; then
      if execute brew install tmux; then
          log_task_success
      else
          log_task_fail
      fi
    else
      log_task_fail # because we switch context to next line if we fallback
      log_warn "brew not found. Fallback to system package implementation: install_package"
      install_package "tmux"
    fi
  else
    log_success "tmux already installed"
  fi
}

function install_zellij() {
  if ! command -v zellij >/dev/null 2>&1; then
      log_task_start "Installing zellij"
      if execute cargo binstall -y zellij; then
        log_task_success
      else
        log_task_fail
      fi
  else
      log_success "zellij already installed"
  fi
}

function install_starship() {
  log_task_start "Installing starship"
  if is_darwin; then
    if execute brew install starship; then
        log_task_success
    else
        log_task_fail
    fi
  else
    if command -v starship >/dev/null 2>&1; then
      log_task_success
      log_success "starship already installed"
    else
      if curl -sS https://starship.rs/install.sh | sh -s -- -y >/dev/null 2>&1; then
        log_task_success
      else
        log_task_fail
      fi
    fi
  fi
}

function install_atuin() {
  log_task_start "Installing atuin"
  if command -v atuin >/dev/null 2>&1; then
    log_task_success
    log_success "atuin already installed"
  else
    if execute curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh; then
        log_task_success
    else
        log_task_fail
    fi
  fi
}

function install_pyenv() {
  log_task_start "Installing pyenv"
  if is_darwin; then
    if execute brew install pyenv pyenv-virtualenv; then
        log_task_success
    else
        log_task_fail
    fi
  else
    if [[ -d ~/.pyenv ]]; then
      log_task_success
      log_success "pyenv already installed"
    else
      if execute curl https://pyenv.run | bash; then
        log_task_success
      else
        log_task_fail
      fi
    fi
  fi
}

function install_python_version() {
  log_task_start "Installing python 3.12"
  export PYENV_ROOT="$HOME/.pyenv"
  [[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
  if command -v pyenv >/dev/null 2>&1; then
      eval "$(pyenv init -)"
      if execute pyenv install --skip-existing 3.12; then
        log_task_success
      else
        log_task_fail
      fi
  else
      log_task_fail
      log_error "pyenv not found, skipping python 3.12 install"
  fi
}

function install_fonts_and_ui() {
  if is_darwin; then
    log_task_start "Installing fonts"
    if execute brew install font-meslo-lg-nerd-font; then
        log_task_success
    else
        log_task_fail
    fi


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
    execute git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
  else
    log_success "tmux plugin manager already installed"
  fi
}

function install_orbstack() {
  if is_darwin; then
      if ! command -v orb; then
        execute brew install orbstack
      fi
  fi
}

# ==============================================================================
# Main Execution Logic
# ==============================================================================

function main() {
    log_info "Starting Setup..."

    # Refresh sudo privileges upfront to prevent hidden prompt issues with 'execute'
    if command -v sudo >/dev/null 2>&1; then
        sudo -v
        # Keep-alive: update existing sudo time stamp if set, otherwise do nothing.
        while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
    fi

    install_homebrew
    install_core_tools
    install_core_packages
    install_linux_basics

    install_lazygit
    install_lazyjournal

    setup_shell
    install_rust
    install_dust

    setup_ssh_keys
    setup_dotfiles

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
