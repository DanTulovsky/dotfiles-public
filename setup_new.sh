#! /bin/bash -x
#
set -e

shopt -s expand_aliases
required_commands="git zsh fzf keychain tmux"
linux_required_commands="ssh-askpass"
linux_required_packages="build-essential"

# all OS
for com in ${required_commands}; do
  if command -v "${com}" >/dev/null 2>&1; then
          echo "${com} available"
  else
          echo "${com} is required"
          if uname -o |grep -i linux; then
            if ! sudo apt install "${com}"; then
              exit 1
            fi
          elif uname -o |grep -i darwin; then
            if ! brew install "${com}"; then
              exit 1
            fi
          else
            exit 1
          fi
  fi
done

# Linux
for com in ${linux_required_commands}; do
  if command -v ${com} >/dev/null 2>&1; then
          echo "${com} available"
  else
    echo "${com} is required"
    if uname -o |grep -i linux; then
      if ! sudo apt install -y ${com}; then
        exit 1
      fi
    fi
  fi
done

# Linux required packages
if uname -o |grep -i linux; then
  for pkg in ${linux_required_packages}; do
    if dpkg -l |grep -i "${pkg}" >/dev/null 2>&1; then
      echo "${pkg} available"
    else
      echo "${pkg} is required"
      if ! sudo apt install -y "${pkg}"; then
        exit 1
      fi
    fi
  done
fi

echo "Installing pyenv..."
rm -rf "${HOME}"/.pyenv
if uname -o |grep -i darwin; then
  brew install pyenv pyenv-virtualenv
else
  curl https://pyenv.run |bash
fi

echo "Installing cargo..."
curl https://sh.rustup.rs -sSf | sh

if ! echo "${SHELL}" |grep zsh >/dev/null 2>&1; then
  echo "Setting default shell to zsh..."
  sudo -u "$USER" chsh -s "$(which zsh)"
  echo "Please restart shell to switch to zsh and run this again..."
  exit 1
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
git clone --bare git@github.com:DanTulovsky/dotfiles-config.git "${ZDOTDIR:-$HOME}"/.cfg
config reset --hard HEAD
config config --local status.showUntrackedFiles no

# install zprezto
rm -rf "${ZDOTDIR:-$HOME}"/.zprezto
git clone --recursive https://github.com/sorin-ionescu/prezto.git "${ZDOTDIR:-$HOME}/.zprezto"

# install fonts
if uname |grep -i darwin; then
  brew tap homebrew/cask-fonts
  brew install font-meslo-lg-nerd-font
else
  echo ""
  echo "Install fonts from: https://github.com/romkatv/powerlevel10k?tab=readme-ov-file#fonts"
  echo ""
fi
