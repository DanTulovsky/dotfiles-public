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
    # Initial Mac Setup
    if is_darwin; then
      if ! command -v brew > /dev/null 2>&1; then
        log_task_start "Installing Homebrew"
        if execute /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
            log_success
        else
            log_task_fail
        fi
        log_task_start "Installing Homebrew packages"
        if execute brew install curl wget git fzf keychain tmux vim fish direnv; then
            log_success
        else
            log_task_fail
        fi
      fi
    fi

    # Install Homebrew on Linux if missing
    if ! command -v brew >/dev/null 2>&1; then
         if is_linux; then
            log_task_start "Installing Homebrew for Linux"
            if NONINTERACTIVE=1 execute /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
                eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
                log_success
            else
                log_task_fail
            fi
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
    log_task_start "Instaling/updating Rust"
    if ! command -v cargo >/dev/null 2>&1; then
      if curl https://sh.rustup.rs -sSf | sh -s -- -y >/dev/null 2>&1; then
          export PATH="$HOME/.cargo/bin:$PATH"
          log_success
      else
          log_task_fail
      fi
    else
        log_success
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

  # Check if command contains sudo - if so, we need to handle prompts differently
  local cmd_has_sudo=false
  if [[ "$cmd_string" == *"sudo"* ]]; then
    cmd_has_sudo=true
  fi

  local exit_code=0
  local pid=""

  # For sudo commands, run in foreground to allow prompts to be visible
  # For other commands, run in background with spinner
  if [[ "$cmd_has_sudo" == "true" ]]; then
    # Run sudo command in foreground so prompts are visible
    # Still capture output to log file
    if [[ "${EXECUTE_LOG_APPEND:-}" == "true" ]]; then
        "$@" 2>&1 | tee -a "$temp_log"
    else
        "$@" 2>&1 | tee "$temp_log"
    fi
    exit_code=${PIPESTATUS[0]}
  else
    # For non-sudo commands, run in background with spinner
    if [[ "${EXECUTE_LOG_APPEND:-}" == "true" ]]; then
        "$@" >> "$temp_log" 2>&1 &
    else
        "$@" > "$temp_log" 2>&1 &
    fi
    pid=$!

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

    # Wait for the process and capture exit code
    # Temporarily disable ERR trap and set -e to prevent trap from firing before we capture error
    local saved_trap
    saved_trap="$(trap -p ERR 2>/dev/null || echo 'trap catch_error ERR')"
    set +e  # Temporarily disable exit on error
    trap '' ERR  # Disable ERR trap temporarily
    wait "$pid"
    exit_code=$?
    # Re-enable set -e and ERR trap
    set -e
    eval "$saved_trap" 2>/dev/null || trap 'catch_error $?' ERR
  fi

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
    # Clean up the spinner line artifact
    printf "       \b\b\b\b\b\b\b"

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

  # Close initial task
  log_success

  if command -v brew >/dev/null 2>&1; then
      log_task_start "Installing terraform-ls via brew"
      if execute brew install hashicorp/tap/terraform-ls; then
        log_success
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
  if command -v lazygit >/dev/null 2>&1; then
    log_task_start "Checking lazygit"
    log_success
    return
  fi

  log_task_start "Installing lazygit"

  if is_darwin; then
    if execute brew install lazygit; then
        log_success
    else
        log_task_fail
    fi
    return
  fi

  if is_fedora; then
    execute sudo dnf -y copr enable dejan/lazygit
    if execute sudo dnf install -y lazygit; then
        log_success
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
    # Skip apt install on Pop!_OS as lazygit is not available in their repos
    if is_pop_os; then
      # Fall through to manual installation
      :
    else
      local major
      local minor
      major="$(get_os_release_major_version)"
      minor="$(get_os_release_minor_version)"
      if [[ -n ${major} && -n ${minor} ]] && { (( major > 25 )) || (( major == 25 && minor >= 10 )); }; then
        execute sudo apt install -y lazygit
        return
      fi
    fi
  fi

  tmpdir="$(mktemp -d)"
  local lazygit_error_log
  lazygit_error_log="$(mktemp)"

  # Run subshell with error capture
  # Don't use set -e in subshell as it will exit immediately and we want to capture the error
  if (
    cd "${tmpdir}" || exit 1
    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": *"v\K[^"]*' || echo "")
    if [[ -z "$LAZYGIT_VERSION" ]]; then
      echo "Failed to get lazygit version" >&2
      exit 1
    fi
    curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" || exit 1
    tar xf lazygit.tar.gz lazygit || exit 1
    sudo install lazygit -D -t /usr/local/bin/ || exit 1
  ) > "$lazygit_error_log" 2>&1; then
    rm -f "$lazygit_error_log"
    rm -rf "${tmpdir}"
    log_success
  else
    local exit_code=$?
    # Capture error details BEFORE calling log_task_fail (which calls exit)
    FAILED_COMMAND="lazygit installation (curl/tar/install in subshell)"
    FAILED_COMMAND_LINE="${BASH_LINENO[0]}"
    FAILED_COMMAND_OUTPUT="$(cat "$lazygit_error_log" 2>/dev/null || echo "Could not read error log")"

    # Print error details before exiting
    log_error "lazygit installation failed with exit code $exit_code"
    echo "--- Error Output ---" >&2
    cat "$lazygit_error_log" >&2
    echo "--- End Error Output ---" >&2
    rm -f "$lazygit_error_log"
    rm -rf "${tmpdir}"

    # Now call log_task_fail which will exit and trigger ERR trap
    # But FAILED_COMMAND should already be set
    log_task_fail
  fi
}

function install_lazyjournal() {
  if command -v lazyjournal >/dev/null 2>&1; then
    log_task_start "Checking lazyjournal"
    log_success
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
  log_task_start "Installing cargo-binstall"
  if ! command -v cargo-binstall >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        if execute brew install cargo-binstall; then
            log_success
        else
            log_task_fail
        fi
    else
        log_warn "Manual install of cargo-binstall required on Linux if brew is missing"
        # Optional: cargo install cargo-binstall
    fi
  else
    log_success
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
  if ! command -v sk >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      if execute brew install sk; then
          log_success
      else
          log_task_fail
      fi
    else
      log_task_fail
      log_warn "brew not found, cannot install sk"
    fi
  else
    log_success
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
  if ! command -v zellij >/dev/null 2>&1; then
      if execute cargo binstall -y zellij; then
        log_success
      else
        log_task_fail
      fi
  else
      log_success
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
    if execute bash -c "curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh"; then
        log_success
    else
        log_task_fail
    fi
  fi
}

function install_pyenv() {
  log_task_start "Installing pyenv"
  if is_darwin; then
    if execute brew install pyenv pyenv-virtualenv; then
        log_success
    else
        log_task_fail
    fi
  else
    if [[ -d ~/.pyenv ]]; then
      log_success
    else
      if execute bash -c "curl https://pyenv.run | bash"; then
        log_success
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
  if is_darwin; then
    log_task_start "Installing Meslo Nerd Fonts"
    if execute brew install font-meslo-lg-nerd-font; then
        log_success
    else
        log_task_fail
    fi


    defaults write com.microsoft.VSCodeExploration ApplePressAndHoldEnabled -bool false
    defaults delete -g ApplePressAndHoldEnabled || true
  else
    log_task_start "Installing Meslo Nerd Fonts"
    if is_debian || is_ubuntu; then
        execute sudo apt install -y fontconfig unzip
    elif is_fedora; then
        execute sudo dnf install -y fontconfig unzip
    fi

    if execute brew install font-meslo-lg-nerd-font; then
        log_success
    else
        log_task_fail
    fi
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
        # Check if sudo supports timestamp caching by trying to validate
        # If timestamp caching is not supported, sudo -v will always prompt
        local sudo_supports_timestamp=false
        if sudo -n true 2>/dev/null; then
            # Already have a valid timestamp, so caching is supported
            sudo_supports_timestamp=true
        else
            # Try to establish a timestamp
            if sudo -v 2>/dev/null; then
                # If sudo -v succeeded without prompting, timestamp caching is supported
                sudo_supports_timestamp=true
            else
                # sudo -v prompted for password, which means either:
                # 1. No timestamp exists yet (normal first run)
                # 2. Timestamp caching is not supported
                # We'll prompt for password and then check if we can use -n
                sudo -v || {
                    log_error "Failed to obtain sudo privileges. Exiting."
                    exit 1
                }
                # Now check if -n works (means timestamp caching is supported)
                if sudo -n true 2>/dev/null; then
                    sudo_supports_timestamp=true
                fi
            fi
        fi

        # Only start keep-alive if timestamp caching is supported
        if [[ "$sudo_supports_timestamp" == "true" ]]; then
            # Keep-alive: refresh sudo timestamp every 30 seconds (before default 5min expiry)
            # Use sudo -v to actually refresh the timestamp, not just check it
            # Run in subshell to avoid interfering with main script
            (
                # Ignore signals that might kill this process
                trap '' HUP INT TERM
                # Start refreshing immediately, then every 30 seconds
                while true; do
                    # Check if parent process is still running first
                    if ! kill -0 "$$" 2>/dev/null; then
                        exit 0
                    fi
                    # Refresh sudo timestamp (this extends it, preventing expiry)
                    # Use -v to refresh, but don't suppress errors completely - if it fails, exit
                    if ! sudo -v 2>/dev/null; then
                        # If sudo -v fails, the timestamp might have expired
                        # Try one more time, and if it still fails, exit
                        sleep 1
                        if ! sudo -v 2>/dev/null; then
                            exit 0
                        fi
                    fi
                    # Wait 30 seconds before next refresh (more frequent to prevent expiry)
                    sleep 30
                done
            ) &
            local keepalive_pid=$!
            # Disown the background process so it continues even if parent is in a pipe
            disown "$keepalive_pid" 2>/dev/null || true
        else
            log_warn "sudo timestamp caching not supported on this system. You may be prompted for sudo password multiple times."
        fi
    fi


    pre_install_git
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
