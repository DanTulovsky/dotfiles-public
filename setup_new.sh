#!/bin/bash
#
# setup_new.sh
#
# Sets up a new machine (macOS, Linux - Debian/Ubuntu/Pop!_OS/Fedora) with required tools and configurations.
#

set -e
set -o pipefail
set -E  # Make ERR trap inherit into functions

# Global variables to track the actual failing command
FAILED_COMMAND=""
FAILED_COMMAND_OUTPUT=""
FAILED_COMMAND_LINE=""

# Trap to ensure errors are visible even when set -e exits the script
trap 'last_command=$BASH_COMMAND' DEBUG
trap 'catch_error $?' ERR

function catch_error() {
  local exit_code=$1
  echo "" >&2
  echo "========================================" >&2
  echo "ERROR: Script failed!" >&2
  echo "Exit code: $exit_code" >&2

  # Show the actual failing command if we captured it
  # Use a local copy to avoid issues with variable scope
  local failed_cmd="${FAILED_COMMAND:-}"
  local failed_line="${FAILED_COMMAND_LINE:-}"
  local failed_output="${FAILED_COMMAND_OUTPUT:-}"

  if [[ -n "$failed_cmd" ]]; then
    echo "Failed command: $failed_cmd" >&2
    if [[ -n "$failed_line" ]]; then
      echo "Line: $failed_line" >&2
    fi
    if [[ -n "$failed_output" ]]; then
      echo "" >&2
      echo "--- Error Output ---" >&2
      echo "$failed_output" >&2
      echo "--- End Error Output ---" >&2
    else
      echo "" >&2
      echo "--- Error Output ---" >&2
      echo "(No error output captured)" >&2
      echo "--- End Error Output ---" >&2
    fi
  else
    # Fallback to default behavior if we didn't capture the command
    echo "Failed command: $last_command" >&2
    echo "Line: ${BASH_LINENO[0]}" >&2
    echo "" >&2
    echo "Note: Error details were not captured. This may indicate an error occurred" >&2
    echo "      in a subshell or before error handling was initialized." >&2
    echo "" >&2
    echo "Debug info:" >&2
    echo "  FAILED_COMMAND='${FAILED_COMMAND:-<empty>}'" >&2
    echo "  FAILED_COMMAND_LINE='${FAILED_COMMAND_LINE:-<empty>}'" >&2
    echo "  FAILED_COMMAND_OUTPUT length: ${#FAILED_COMMAND_OUTPUT}" >&2
  fi

  echo "========================================" >&2
  # Flush output to ensure visibility when piped
  exec 1>&-
  exec 2>&-
}

VERBOSE=false

# Parse arguments
for arg in "$@"; do
  case $arg in
    --verbose)
      VERBOSE=true
      shift
      ;;
  esac
done

function pre_install_git() {
    # Ensure git is installed before Homebrew on Linux
    if is_linux; then
        if ! command -v git >/dev/null 2>&1; then
             install_package "git"
        fi
        # Also ensure curl is present
        if ! command -v curl >/dev/null 2>&1; then
             install_package "curl"
        fi
    fi
}

function install_homebrew() {
    if command -v brew >/dev/null 2>&1; then
        return
    fi

    log_task_start "Installing Homebrew"

    # Install Homebrew non-interactively
    if NONINTERACTIVE=1 execute /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        # Eval shellenv based on platform and architecture
        if is_linux && [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
            eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
        elif is_darwin && [[ -x /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif is_darwin && [[ -x /usr/local/bin/brew ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        log_success
    else
        log_task_fail
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

function install_brew_packages() {
    # --- Install Brew Packages ---
    log_task_start "Installing brew packages (${#BREW_PACKAGES[@]} packages)"
    if execute brew install "${BREW_PACKAGES[@]}"; then
        log_success
    else
        log_task_fail
    fi

    # Run custom homebrew apps script if it exists (macOS only)
    if is_darwin && [ -f ~/.homebrew_apps ]; then
        log_info "Running custom ~/.homebrew_apps script"
        if execute bash ~/.homebrew_apps; then
            log_success "Custom homebrew apps installed"
        else
            log_warn "Custom homebrew apps script failed, continuing..."
        fi
    fi
}

function install_linux_basics() {
    # --- Linux Specifics ---
    if is_linux; then
        for cmd in "${LINUX_REQUIRED_COMMANDS[@]}"; do
             local package
             package=$(get_linux_package_name "${cmd}")
             ensure_command "${cmd}" "${package}"
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
             log_task_start "Generating locales"
             if execute sudo locale-gen en_US.UTF-8; then
                 log_success
             else
                 log_warn "Failed to generate locales"
             fi

             if is_debian; then
                 for pkg in "${DEBIAN_REQUIRED_PACKAGES[@]}"; do
                     install_package "${pkg}"
                 done
                 # Snaps
                 for pkg in "${SNAP_REQUIRED_PACKAGES[@]}"; do
                    log_task_start "Installing ${pkg} (snap)"
                    if execute sudo snap install "${pkg}" --classic; then
                        log_success
                    else
                        log_warn "Failed to install ${pkg} via snap"
                    fi
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
    log_task_start "Checking default shell"
    if ! echo "${SHELL}" | grep fish >/dev/null 2>&1; then
      log_success "Shell is not fish"
      log_info "Setting default shell to fish..."
      if command -v fish >/dev/null 2>&1; then
        if is_linux; then
          execute sudo usermod -s "$(which fish)" "$USER"
        elif is_darwin; then
          execute sudo dscl . -create "/Users/$USER" UserShell "$(which fish)"
        fi
        log_warn "Default shell changed to fish. Please logout and login again for this to take effect."
        # Continue execution
      else
        log_error "fish is not installed"
        exit 1
      fi
    else
      log_success
    fi
}

function install_rust() {
    # --- Cargo / Rust ---
    log_task_start "Installing Rust"
    if command -v cargo >/dev/null 2>&1; then
        log_success
    else
        if execute brew install rust; then
            log_success
        else
            log_task_fail
        fi
    fi
}

function install_dust() {
    log_task_start "Installing dust"
    if ! command -v dust >/dev/null 2>&1; then
      if execute cargo install du-dust; then
        log_success
      else
        log_task_fail
      fi
    else
      log_success
    fi
}

function setup_ssh_keys() {
    # --- SSH Keys ---
    local git_identity_file="${HOME}/.ssh/identity.git"
    if [ ! -f "${git_identity_file}" ]; then
      log_info "Generating ssh key for github into ${git_identity_file}"
      ssh-keygen -t ed25519 -f "${git_identity_file}" -N "" -q
      echo "Add this key to github before continuing: https://github.com/settings/keys"
      echo ""
      cat "${git_identity_file}.pub"
      echo ""

      # Verify SSH key with retry loop
      local key_verified=false
      while [ "$key_verified" = false ]; do
        if [ -c /dev/tty ]; then
            read -rp "Press Enter once you have added the key to GitHub to continue..." < /dev/tty
            echo ""
            log_info "Verifying SSH key with GitHub..."
            local ssh_output
            ssh_output=$(ssh -i "${git_identity_file}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -T git@github.com 2>&1 || true)
            if echo "$ssh_output" | grep -qi "successfully authenticated"; then
                log_success "SSH key verified successfully!"
                key_verified=true
            else
                log_error "SSH key verification failed. Please ensure you've added the key to GitHub."
                echo ""
                echo "SSH test output:"
                echo "$ssh_output"
                echo ""
                echo "Public key (copy this to GitHub):"
                cat "${git_identity_file}.pub"
                echo ""
            fi
        else
            log_warn "Cannot pause for input (no /dev/tty detected). Continuing without verification..."
            key_verified=true
        fi
      done
    fi
}

function setup_dotfiles() {
    # --- Dotfiles Configuration ---
    log_task_start "Configuring dotfiles"

    if ! grep ".cfg" "$HOME/.gitignore" >/dev/null 2>&1; then
      execute echo ".cfg" >> "$HOME/.gitignore"
    fi
    # Close the "Configuring dotfiles..." incomplete line with success before starting new logs
    log_success

    log_task_start "Starting ssh agent"
    execute keychain --nogui ~/.ssh/identity.git
    log_success
    # shellcheck disable=SC1090
    if [ -f ~/.keychain/"$(hostname)"-sh ]; then
        source ~/.keychain/"$(hostname)"-sh
    fi

    # helper for config command
    function config() {
      git --git-dir="$HOME/.cfg/" --work-tree="$HOME" "$@"
    }

    execute rm -rf "$HOME"/.cfg
    log_task_start "Cloning dotfiles-config"
    if GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" execute git clone --bare git@github.com:DanTulovsky/dotfiles-config.git "$HOME"/.cfg; then
        execute config reset --hard HEAD
        execute config config --local status.showUntrackedFiles no
        log_success
    else
        log_task_fail
    fi
}

# ==============================================================================
# Constants & Configuration
# ==============================================================================

POST_INSTALL_MESSAGES=()

# Core tools required on all systems
REQUIRED_COMMANDS=(
  git
  fzf
  keychain
  vim
  fish
  unzip
)

# Core packages required on all systems
REQUIRED_PACKAGES=(
  git
  htop
  btop
  npm
  golang
  rclone
  duf
  lsd
  ripgrep
  jq
)

# Brew packages (tools installed via Homebrew)
BREW_PACKAGES=(
  # Development tools
  curl
  wget
  direnv
  pyenv
  pyenv-virtualenv
  starship
  atuin
  rust
  cargo-binstall
  sk
  tmux
  zellij
  lazygit
  lazyjournal

  # Language servers
  vscode-langservers-extracted
  dockerfile-language-server
  sql-language-server
  typescript
  typescript-language-server
  yaml-language-server
  gopls
  delve
  goimports
  terraform-ls
  taplo

  # Fonts
  font-meslo-lg-nerd-font

  # Tools
  cheat
  tldr
  chafa
  zoxide
  procs
  go-task/tap/go-task
  viddy
  wader/tap/fq
  dive
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

FEDORA_PACKAGE_OVERRIDES=(
  "ssh-askpass:openssh-askpass"
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
  if [ -z "$1" ]; then
    echo -e "\033[32m[OK]\033[0m"
  else
    echo -e "\033[32m[OK]\033[0m $*"
  fi
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

function log_task_fail() {
  if [ -n "$1" ]; then
      echo -e "\033[31m[FAILED]\033[0m $1"
  else
      echo -e "\033[31m[FAILED]\033[0m"
  fi
  # Before exiting, ensure FAILED_COMMAND is set if it's not already
  # This helps when log_task_fail is called directly without going through execute
  if [[ -z "$FAILED_COMMAND" ]]; then
    FAILED_COMMAND="${last_command:-log_task_fail called}"
    FAILED_COMMAND_LINE="${BASH_LINENO[0]}"
  fi
  exit 1
}

# ==============================================================================
# Execution Helpers
# ==============================================================================

function execute() {
  local silent=false
  if [[ "$1" == "-s" ]]; then
    silent=true
    shift
  fi

  # Capture the command string early for error reporting
  local cmd_string="$*"

  local temp_log
  local keep_log=false

  if [[ -n "${EXECUTE_LOG_FILE:-}" ]]; then
    temp_log="${EXECUTE_LOG_FILE}"
    keep_log=true
  else
    temp_log=$(mktemp)
  fi

  # Run command and capture output
  # Temporarily disable ERR trap and set -e to prevent trap from firing before we capture error
  local saved_trap
  saved_trap="$(trap -p ERR 2>/dev/null || echo 'trap catch_error ERR')"
  set +e  # Temporarily disable exit on error
  trap '' ERR  # Disable ERR trap temporarily

  if [[ "${EXECUTE_LOG_APPEND:-}" == "true" ]]; then
      "$@" >> "$temp_log" 2>&1
  else
      "$@" > "$temp_log" 2>&1
  fi
  local exit_code=$?

  # Re-enable set -e and ERR trap
  set -e
  eval "$saved_trap" 2>/dev/null || trap 'catch_error $?' ERR

  # Capture command details immediately when we detect a failure
  # This ensures they're available even if ERR trap fires later
  # CRITICAL: Set globals BEFORE any operation that might trigger ERR trap
  if [ $exit_code -ne 0 ]; then
    # Set globals FIRST, before any other operations
    FAILED_COMMAND="$cmd_string"
    FAILED_COMMAND_LINE="${BASH_LINENO[1]}"
    if [[ -f "$temp_log" ]]; then
      FAILED_COMMAND_OUTPUT="$(cat "$temp_log" 2>/dev/null || echo "Could not read error log")"
    else
      FAILED_COMMAND_OUTPUT="Error log file not found"
    fi
    # Also set local vars for use in this function
    local failed_cmd="$cmd_string"
    local failed_line="${BASH_LINENO[1]}"
    local failed_output="$FAILED_COMMAND_OUTPUT"
  fi

  if [ $exit_code -eq 0 ]; then
    if [[ "$keep_log" == "false" ]]; then
        rm "$temp_log"
    fi
    return 0
  else
    # Print newline for error output
    echo ""

    # Always print errors unless explicitly silenced AND not in verbose mode
    if [[ "$silent" == "true" ]] && [[ "$VERBOSE" == "false" ]]; then
      # Even in silent mode, we should capture the error for the ERR trap
      # But don't print it here
      # FAILED_COMMAND is already set above, so ERR trap will have it
      if [[ "$keep_log" == "false" ]]; then
          rm "$temp_log"
      fi
      return $exit_code
    fi

    # Print error details BEFORE returning (important for set -e)
    log_error "Command failed with exit code $exit_code: $cmd_string"
    echo "--- Error Output ---" >&2
    if [[ -f "$temp_log" ]]; then
      cat "$temp_log" >&2
    else
      echo "Error log file not found or already removed" >&2
    fi
    echo "--- End Error Output ---" >&2

    if [[ "$keep_log" == "false" ]]; then
        rm "$temp_log"
    fi

    # Return the exit code (may trigger set -e, but error is already printed)
    # FAILED_COMMAND is already set above, so ERR trap will have it
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
  # Pop!_OS is Ubuntu-based, so exclude it from Debian detection
  if is_pop_os; then
    return 1
  fi
  [ -f /etc/debian_version ] || (uname -a | grep -i debian > /dev/null 2>&1)
  return $?
}

function is_ubuntu() {
  # Pop!_OS is Ubuntu-based, so treat it as Ubuntu
  if is_pop_os; then
    return 0
  fi
  uname -a | grep -i ubuntu > /dev/null 2>&1
  return $?
}

function is_jammy() {
  if uname -a | grep -i jammy > /dev/null 2>&1; then
    return 0
  fi
  # Also check VERSION_CODENAME from /etc/os-release
  local codename
  codename=$(get_os_release_codename)
  if [[ "$codename" == "jammy" ]]; then
    return 0
  fi
  return 1
}

function is_ubuntu_22_04_or_later() {
  # Check for Ubuntu 22.04 (jammy) or later versions like 24.04 (noble)
  # This is useful for features/packages that require Ubuntu 22.04+
  local codename
  codename=$(get_os_release_codename)
  if [[ "$codename" == "jammy" ]] || [[ "$codename" == "noble" ]]; then
    return 0
  fi
  return 1
}

function is_pop_os() {
  if [ -f /etc/os-release ]; then
    grep -qi "^ID=pop" /etc/os-release
    return $?
  fi
  return 1
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

function get_linux_package_name() {
  local cmd="$1"
  local package="$cmd"

  if is_fedora; then
      for override in "${FEDORA_PACKAGE_OVERRIDES[@]}"; do
          local key="${override%%:*}"
          local value="${override#*:}"
          if [[ "$cmd" == "$key" ]]; then
              package="$value"
              break
          fi
      done
  fi
  echo "$package"
}

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
  log_task_start "Installing ${package}"

  if is_package_installed "${package}"; then
     log_success
     return 0
  fi

  if is_fedora; then
    if ! execute sudo dnf install -y "${fedora_package}"; then
      log_task_fail
      log_warn "dnf failed to install ${fedora_package}"
      if command -v brew >/dev/null 2>&1; then
        log_task_start "Trying brew install ${package}"
        if execute brew install "${package}"; then
            log_success
            return 0
        else
            log_task_fail
            return 1
        fi
      fi
      return 1
    fi
    log_success
  elif is_linux; then
    if ! execute sudo apt install -y "${package}"; then
      log_task_fail
      log_warn "apt failed to install ${package}"
      if command -v brew >/dev/null 2>&1; then
        log_task_start "Trying brew install ${package}"
        if execute brew install "${package}"; then
            log_success
            return 0
        else
            log_task_fail
            return 1
        fi
      fi
      return 1
    fi
    log_success
  elif is_darwin; then
    if ! execute brew install "${package}"; then
      log_task_fail
      log_error "Failed to install ${package}"
      return 1
    fi
    log_success
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
    log_task_start "Checking ${cmd}"
    log_success
  else
    install_package "${package}"
  fi
}

# ==============================================================================
# Specific Install Functions
# ==============================================================================

function lsp_install() {
  log_task_start "Installing Language Servers"

  # Go tools
  execute brew install vscode-langservers-extracted
  execute brew install dockerfile-language-server
  execute brew install sql-language-server
  execute brew install typescript
  execute brew install typescript-language-server
  execute brew install yaml-language-server
  execute brew install gopls
  execute brew install delve
  execute brew install goimports
  execute brew install terraform-ls
  execute brew install taplo

  # Close initial task
  log_success
}

function docker_linux_install() {
  if ! is_linux; then
    return
  fi
  log_task_start "Checking Docker installation for Linux"
  if is_fedora; then
      if execute sudo dnf -y install dnf-plugins-core \
        && execute sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo \
        && execute sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
            log_success
      else
            log_task_fail
      fi
      log_task_start "Adding user to docker group"
      execute sudo usermod -aG docker "$USER" && log_success || log_task_fail
      return
  fi

  if command -v docker >/dev/null 2>&1; then
    log_success
    return
  fi

  # Determine distribution for Docker repo URL
  local dist
  if is_ubuntu; then
    dist="ubuntu"
  elif is_debian; then
    dist="debian"
  else
    log_error "Unsupported distribution for Docker installation"
    return 1
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

  if execute sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    log_success
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
    log_task_start "Checking gcloud"
    log_success
    return
  fi

  log_task_start "Installing Google Cloud SDK"
  if is_fedora; then
    sudo tee /etc/yum.repos.d/google-cloud-sdk.repo > /dev/null << EOM
[google-cloud-cli]
name=Google Cloud CLI
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOM
    if execute sudo dnf install -y google-cloud-cli kubectl; then
      log_success
    else
      log_task_fail
    fi
    return
  fi

  execute bash -c "curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg"
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null
  if execute sudo apt-get update && execute sudo apt-get install -y google-cloud-cli kubectl; then
    log_success
  else
    log_task_fail
  fi
}

function krew_install_plugins() {
  local krew_log
  krew_log="$(mktemp /tmp/krew-install.XXXXXX.log)"
  # Ensure we export for subshell visibility if needed, but we pass via env var to execute
  export EXECUTE_LOG_FILE="$krew_log"
  export EXECUTE_LOG_APPEND="true"

  log_task_start "Installing Krew plugins"
  if (
    cd "$(mktemp -d)" &&
    OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
    ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
    KREW="krew-${OS}_${ARCH}" &&
    execute -s curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
    execute -s tar zxf "${KREW}.tar.gz" &&
    execute -s ./"${KREW}" install krew
  ) && {
      export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
      execute -s hash -r
      execute -s ~/.krew_plugins
  }; then
    log_success
    rm "$krew_log"
  else
    log_warn "Krew install failed, but continuing. Check logs: $krew_log"
  fi

  unset EXECUTE_LOG_FILE
  unset EXECUTE_LOG_APPEND
}

function install_lazygit() {
  log_task_start "Installing lazygit"
  if execute brew install lazygit; then
      log_success
  else
      log_task_fail
  fi
}

function install_lazyjournal() {
  log_task_start "Installing lazyjournal"
  if execute brew install lazyjournal; then
      log_success
  else
      log_task_fail
  fi
}

function install_cargo_binstall() {
  log_task_start "Installing cargo-binstall"
  if execute brew install cargo-binstall; then
      log_success
  else
      log_task_fail
  fi
}

function system_update_linux() {
  log_task_start "Updating system packages"
  if is_fedora; then
      if execute sudo dnf group install -y "development-tools" \
        && execute sudo dnf update -y; then
         log_success
      else
         log_warn "System update failed (non-critical?)"
      fi
  elif is_debian || is_ubuntu; then
      # Skip modernize-sources on Pop!_OS as it doesn't support this command
      if ! is_pop_os; then
          execute -s sudo apt -y modernize-sources || true
      fi
      if [ -f /etc/apt/sources.list ]; then
        if execute sudo sed -i -e 's/^# *deb-src/deb-src/g' /etc/apt/sources.list; then
            :
        else
            log_warn "Failed to enable deb-src in sources.list"
        fi
      fi
      if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
         if execute sudo sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources; then
            :
         else
            log_warn "Failed to enable deb-src in ubuntu.sources"
         fi
      fi
      if execute sudo apt-get update \
        && execute sudo apt-get -y build-dep python3; then
          log_success
      else
          log_warn "System update/build-dep failed (check logs)"
      fi
  fi
}

function install_sk() {
  log_task_start "Installing sk"
  if execute brew install sk; then
      log_success
  else
      log_task_fail
  fi
}

function install_tmux() {
  log_task_start "Installing tmux"
  if ! command -v tmux >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      if execute brew install tmux; then
          log_success
      else
          log_task_fail
      fi
    else
      log_task_fail # because we switch context to next line if we fallback
      log_warn "brew not found. Fallback to system package implementation: install_package"
      install_package "tmux"
    fi
  else
    log_success
  fi
}

function install_zellij() {
  log_task_start "Installing zellij"
  if execute brew install zellij; then
      log_success
  else
      log_task_fail
  fi
}

function install_starship() {
  log_task_start "Installing starship"
  if execute brew install starship; then
      log_success
  else
      log_task_fail
  fi
}

function install_atuin() {
  log_task_start "Installing atuin"
  if command -v atuin >/dev/null 2>&1; then
    log_success
  else
    if execute brew install atuin; then
        log_success
    else
        log_task_fail
    fi
  fi
}

function install_pyenv() {
  log_task_start "Installing pyenv"
  if command -v pyenv >/dev/null 2>&1; then
    log_success
  else
    if execute brew install pyenv pyenv-virtualenv; then
        log_success
    else
        log_task_fail
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
        log_success
      else
        log_task_fail
      fi
  else
      log_task_fail
      log_error "pyenv not found, skipping python 3.12 install"
  fi
}

function install_fonts_and_ui() {
  log_task_start "Installing Meslo Nerd Fonts"
  if execute brew install font-meslo-lg-nerd-font; then
      log_success
  else
      log_task_fail
  fi

  if is_darwin; then
    defaults write com.microsoft.VSCodeExploration ApplePressAndHoldEnabled -bool false
    defaults delete -g ApplePressAndHoldEnabled || true
  fi
}

function install_tpm() {
  touch "$HOME"/.tmux.conf.local
  log_task_start "Installing tmux plugin manager"
  mkdir -p "$HOME/.tmux/plugins"
  if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
    if execute git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm; then
       log_success
    else
       log_task_fail
    fi
  else
    log_success
  fi
}

function install_cheatsheets() {
  log_task_start "Installing cheatsheets"

  if command -v cheatsheets >/dev/null 2>&1; then
    log_success "cheatsheets already installed"
    return 0
  fi

  local dest_dir
  if [[ -d "/opt/homebrew/bin" ]]; then
    dest_dir="/opt/homebrew/bin"
  else
    dest_dir="/usr/local/bin"
  fi

  local dest_path="${dest_dir}/cheatsheets"
  if [[ -x "$dest_path" ]]; then
    log_success "cheatsheets already installed"
    return 0
  fi

  local tmp_file
  tmp_file="$(mktemp)"

  if ! execute curl -fsSL -o "$tmp_file" "https://raw.githubusercontent.com/cheat/cheat/master/scripts/git/cheatsheets"; then
    rm -f "$tmp_file" || true
    log_task_fail
  fi

  if ! execute sudo mkdir -p "$dest_dir"; then
    rm -f "$tmp_file" || true
    log_task_fail
  fi

  if ! execute sudo install -m 0755 "$tmp_file" "$dest_path"; then
    rm -f "$tmp_file" || true
    log_task_fail
  fi

  rm -f "$tmp_file" || true

  mkdir -p ~/.config/cheat/cheatsheets/community
  cheatsheets pull
  log_success
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

    # Add Homebrew to PATH early if it exists (prevents unnecessary reinstallation)
    if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    fi

    # Establish sudo timestamp upfront (will be cleared by Homebrew installer if it runs)
    if command -v sudo >/dev/null 2>&1; then
        sudo -v || {
            log_error "Failed to obtain sudo privileges. Exiting."
            exit 1
        }
    fi

    pre_install_git
    install_homebrew
    install_core_tools
    install_core_packages
    install_linux_basics

    # Install all brew packages (dev tools, language servers, fonts, etc.)
    install_brew_packages

    setup_shell
    install_dust

    setup_ssh_keys
    setup_dotfiles

    install_python_version

    docker_linux_install
    gcloud_linux_install
    install_orbstack
    krew_install_plugins || true
    install_tpm
    install_cheatsheets

    log_success "Setup Complete!"

    if [ ${#POST_INSTALL_MESSAGES[@]} -gt 0 ]; then
        echo ""
        log_info "Manual Steps Required:"
        for msg in "${POST_INSTALL_MESSAGES[@]}"; do
            echo -e "  - \033[33m$msg\033[0m"
        done
        echo ""
    fi
}

main "$@"
