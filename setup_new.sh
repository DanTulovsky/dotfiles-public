#! /bin/bash
#
set -e

shopt -s expand_aliases

# ==============================================================================
# Variables
# ==============================================================================

required_commands="git fzf keychain vim fish"
required_packages="htop btop npm golang rclone duf lsd ripgrep"

# Linux General
linux_required_commands="ssh-askpass"

# Debian/Ubuntu
debian_required_packages="snapd"
ubuntu_common_packages="build-essential zlib1g zlib1g-dev libreadline8 libreadline-dev libssl-dev lzma bzip2 libffi-dev libsqlite3-0 libsqlite3-dev libbz2-dev liblzma-dev pipx ranger locales bzr apt-transport-https ca-certificates gnupg curl direnv bind9-utils"

# Fedora
fedora_required_packages="make automake gcc gcc-c++ kernel-devel zlib-devel readline-devel openssl-devel bzip2-devel libffi-devel sqlite-devel xz-devel pipx ranger gnupg curl direnv bind-utils openssh-askpass dnf-plugins-core"

snap_required_packages=""

# ==============================================================================
# Helper Functions: OS Detection
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
  uname -a | grep -i debian > /dev/null 2>&1
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
  uname -m | grep -i arm > /dev/null 2>&1
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
# Install Functions
# ==============================================================================

function add_hashicorp_repo() {
  if is_fedora; then
    if [[ -e /etc/yum.repos.d/hashicorp.repo ]]; then
      echo "Hashicorp repo already added"
      return
    fi
    sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
  else
    if [[ -e /etc/apt/sources.list.d/hashicorp.list ]]; then
      echo "Hashicorp repo already added"
      return
    fi
    wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt update
  fi
}

function lsp_install() {
  sudo npm install -g n
  sudo n stable

  sudo npm i -g "awk-language-server@>=0.5.2"
  sudo npm i -g bash-language-server
  sudo npm i -g vscode-langservers-extracted
  sudo npm i -g dockerfile-language-server-nodejs
  sudo npm i -g dot-language-server
  sudo npm i -g graphql-language-service-cli
  go install golang.org/x/tools/gopls@latest
  go install github.com/go-delve/delve/cmd/dlv@latest
  go install golang.org/x/tools/cmd/goimports@latest
  sudo npm i -g sql-language-server

  if is_darwin; then
    brew install hashicorp/tap/terraform-ls
  fi
  if is_linux; then
    add_hashicorp_repo
    if is_fedora; then
      sudo dnf install -y terraform-ls
    else
      sudo apt install -y terraform-ls
    fi
  fi

  cargo install taplo-cli --locked --features lsp
  sudo npm i -g typescript typescript-language-server
  sudo npm i -g yaml-language-server@next
}

function docker_linux_install() {
  if is_fedora; then
      sudo dnf -y install dnf-plugins-core
      sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
      sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      sudo systemctl start docker
      sudo usermod -aG docker "$USER"
      return
  fi

  dist=""
  if is_debian; then
    dist="debian"
  fi
  if is_ubuntu; then
    dist="ubuntu"
  fi
  if [ -z "${dist}" ]; then
    echo "Unsupported distribution for Docker install"
    return
  fi

  sudo apt-get update
  sudo apt-get install ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/"${dist}"/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  if [[ ! -e /etc/apt/sources.list.d/docker.list ]]; then
    # Add the repository to Apt sources:
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${dist} \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
  else
    echo "Docker repository already added"
  fi
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
}

function gcloud_linux_install() {
  if command -v gcloud; then
    return
  fi

  if is_fedora; then
    sudo tee /etc/yum.repos.d/google-cloud-sdk.repo << EOM
[google-cloud-cli]
name=Google Cloud CLI
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64
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
  ~/.krew_plugins
}

function install_lazygit() {
  if command -v lazygit >/dev/null 2>&1; then
    echo "lazygit already installed"
    return
  fi

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
    echo "Skipping lazygit install: unsupported OS"
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
    echo "lazyjournal already installed"
    return
  fi

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

# ==============================================================================
# Main Execution Logic
# ==============================================================================

# initial mac setup
if is_darwin; then
  if ! command -v brew > /dev/null 2>&1; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    brew install curl wget git fzf keychain tmux vim fish direnv
  fi
fi

# Required Commands
for com in ${required_commands}; do
  if command -v "${com}" >/dev/null 2>&1; then
    echo "${com} available"
  else
    echo "${com} is required"
    if is_fedora; then
      if ! sudo dnf install -y "${com}"; then
        exit 1
      fi
    elif is_linux; then
      if ! sudo apt install -y "${com}"; then
        exit 1
      fi
    elif is_darwin; then
      if ! brew install "${com}"; then
        exit 1
      fi
    else
      exit 1
    fi
  fi
done

# Required Packages
for pkg in ${required_packages}; do
  if is_fedora; then
     if [[ ${pkg} = "golang" ]]; then
        # Fedora usually has recent go, or user might want specific version.
        # 'golang' package is standard in Fedora.
        if ! sudo dnf install -y golang; then
             exit 1
        fi
        continue
     fi
     # Map generic names to Fedora if needed, or assume they exist
     # htop, btop, npm, rclone, duf, lsd, ripgrep are all standard or common
     if ! sudo dnf install -y "${pkg}"; then
        exit 1
     fi
  elif is_linux; then
    if [[ ${pkg} = "golang" ]]; then
      if is_jammy; then
        sudo apt install snapd
        sudo snap install --classic --channel=1.22/stable go
        continue
      fi
    fi
    if ! sudo apt install -y "${pkg}"; then
      exit 1
    fi
  elif is_darwin; then
    if ! brew install "${pkg}"; then
      exit 1
    fi
  else
    exit 1
  fi
done

# Linux Specific Commands
for com in ${linux_required_commands}; do
  if command -v "${com}" >/dev/null 2>&1; then
          echo "${com} available"
  else
    echo "${com} is required"
    if is_fedora; then
      # ssh-askpass handling on Fedora
      if [[ "${com}" == "ssh-askpass" ]]; then
         if ! sudo dnf install -y openssh-askpass; then
             exit 1
         fi
      else
         if ! sudo dnf install -y "${com}"; then
           exit 1
         fi
      fi
    elif is_linux; then
      if ! sudo apt install -y "${com}"; then
        exit 1
      fi
    fi
  fi
done

# Linux Required Packages & Configuration
if is_linux; then
  if is_fedora; then
      sudo dnf group install -y "development-tools"
      for pkg in ${fedora_required_packages}; do
         if ! sudo dnf install -y "${pkg}"; then
            exit 1
         fi
      done
  else
      # Debian/Ubuntu logic
      sudo sed -i -e 's/^# *deb-src/deb-src/g' /etc/apt/sources.list
      if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
         sudo sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
      fi
      sudo apt-get update
      sudo apt-get -y build-dep python3

      for pkg in ${ubuntu_common_packages}; do
        if dpkg -l | grep -i "${pkg}" >/dev/null 2>&1; then
          echo "${pkg} available"
        else
          echo "${pkg} is required"
          if ! sudo apt install -y "${pkg}"; then
            exit 1
          fi
        fi
      done

      sudo locale-gen en_US.UTF-8

      if is_debian; then
        for pkg in ${debian_required_packages}; do
          if ! sudo apt install -y "${pkg}"; then
            exit 1
          fi
        done

        # snap packages
        for pkg in ${snap_required_packages}; do
          if ! sudo snap install "${pkg}" --classic; then
            exit 1
          fi
        done
      fi
  fi
fi

install_lazygit
install_lazyjournal

# set fish as default shell (before cargo so rustup detects fish)
if ! echo "${SHELL}" | grep fish >/dev/null 2>&1; then
  echo "Setting default shell to fish..."
  if command -v fish >/dev/null 2>&1; then
    if is_linux; then
      sudo -u "$USER" chsh -s "$(which fish)"
    elif is_darwin; then
      sudo dscl . -create "/Users/$USER" UserShell "$(which fish)"
    fi
    echo "Default shell changed to fish. Please logout and log back in, then run this script again."
    # We exit here because shell change requires relogin
    exit 0
  else
    echo "Error: fish is not installed"
    exit 1
  fi
else
  echo "fish is already the default shell"
fi

echo "Installing cargo..."
if ! command -v cargo; then
  curl https://sh.rustup.rs -sSf | sh
  # rustup automatically detects fish and adds to ~/.config/fish/config.fish
  # Add cargo to PATH for current session
  export PATH="$HOME/.cargo/bin:$PATH"
fi

echo "Installing dust..."
if ! command -v dust >/dev/null 2>&1; then
  cargo install du-dust
else
  echo "dust already installed"
fi

# setup ssh key
git_identity_file="${HOME}/.ssh/identity.git"

if [ ! -f "${git_identity_file}" ]; then
  echo "Generating ssh key for github into ${git_identity_file}"
  ssh-keygen -f "${git_identity_file}"
  echo "Add this key to github before continuing: https://github.com/settings/keys"
  echo ""
  cat "${git_identity_file}".pub
  exit 1
fi

###############################################################################################
# CONFIG
###############################################################################################
echo "Removing old config..."
rm -rf "$HOME"/.cfg
alias config='git --git-dir=$HOME/.cfg/ --work-tree=$HOME'

if ! grep ".cfg" .gitignore >/dev/null 2>&1; then
  echo ".cfg" >> .gitignore
fi

echo "Starting ssh agent..."
keychain --nogui ~/.ssh/identity.git
# shellcheck disable=SC1090
source ~/.keychain/"$(hostname)"-sh

echo "Cloning dotfiles..."
git clone --bare git@github.com:DanTulovsky/dotfiles-config.git "$HOME"/.cfg
config reset --hard HEAD
config config --local status.showUntrackedFiles no
###############################################################################################
# END CONFIG
###############################################################################################

echo "Installing pyenv..."
if is_darwin; then
  brew install pyenv pyenv-virtualenv
else
  if [[ -d ~/.pyenv ]]; then
    echo "pyenv already installed"
  else
    curl https://pyenv.run | bash
  fi
fi

echo "Installing starship..."
if is_darwin; then
  brew install starship
else
  if command -v starship >/dev/null 2>&1; then
    echo "starship already installed"
  else
    curl -sS https://starship.rs/install.sh | sh
  fi
fi

echo "Installing atuin..."
if command -v atuin >/dev/null 2>&1; then
  echo "atuin already installed"
  else
  curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh
fi

echo "Installing python 3.12..."
# Ensure pyenv is usable in this session
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

pyenv install --skip-existing 3.12

# install language servers
lsp_install

# install homebrew (Linux handled if missing)
if command -v brew; then
  echo "brew already installed"
else
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Add brew to path for Linux if just installed
  if is_linux; then
      eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi

  # install homebrewapp
  if [[ -e ~/.homebrew_apps ]]; then
    if is_darwin; then
      ~/.homebrew_apps
    fi
  fi
fi

# install cargo-binstall
if ! command -v cargo-binstall >/dev/null 2>&1; then
  echo "Installing cargo-binstall..."
  brew install cargo-binstall
else
  echo "cargo-binstall already installed"
fi

# install sk
if ! command -v sk >/dev/null 2>&1; then
  echo "Installing sk..."
  brew install sk
else
  echo "sk already installed"
fi

# install zellij
if ! command -v zellij >/dev/null 2>&1; then
  echo "Installing zellij..."
  cargo binstall -y zellij
else
  echo "zellij already installed"
fi

# install tmux
if ! command -v tmux >/dev/null 2>&1; then
  echo "Installing tmux..."
  brew install tmux
else
  echo "tmux already installed"
fi

# install docker or equivalent
if is_linux; then
  docker_linux_install
fi
if is_darwin; then
  if ! command -v orb; then
    brew install orbstack
  fi
fi

# install gcloud
if is_linux; then
  gcloud_linux_install
fi

# install krew; ignore failures
krew_install_plugins || true

# install fonts
if is_darwin; then
  brew install font-meslo-lg-nerd-font
else
  echo ""
  echo "Install fonts from: https://github.com/romkatv/powerlevel10k?tab=readme-ov-file#fonts"
  echo ""
fi

# setup vscode key repeat
if is_darwin; then
  defaults write com.microsoft.VSCode ApplePressAndHoldEnabled -bool false              # For VS Code
  defaults write com.microsoft.VSCodeInsiders ApplePressAndHoldEnabled -bool false      # For VS Code Insider
  defaults write com.vscodium ApplePressAndHoldEnabled -bool false                      # For VS Codium
  defaults write com.microsoft.VSCodeExploration ApplePressAndHoldEnabled -bool false   # For VS Codium Exploration users
  defaults delete -g ApplePressAndHoldEnabled
fi

touch "$HOME"/.tmux.conf.local

echo "Installing tmux plugin manager..."
mkdir -p "$HOME/.tmux/plugins"
if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
  git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
else
  echo "tmux plugin manager already installed"
fi
