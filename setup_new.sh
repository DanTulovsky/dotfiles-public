#! /bin/bash -x
#
set -e

shopt -s expand_aliases
required_commands="git zsh fzf keychain"
linux_required_commands="ssh-askpass"

# all OS
for com in ${required_commands}; do
  if command -v $com >/dev/null 2>&1; then
          echo "$com available"
  else
          echo "$com is required"
          if uname -o |grep -i linux; then
            sudo apt install $com
            if [ $? != 0 ]; then
              exit 1
            fi
          elif uname -o |grep -i darwin; then
            brew install $com
            if $! != 0; then
              exit 1
            fi
          else
            exit 1
          fi
  fi
done

# Linux
for com in ${linux_required_commands}; do
  if command -v $com >/dev/null 2>&1; then
          echo "$com available"
  else
    echo "$com is required"
    if uname -o |grep -i linux; then
      sudo apt install $com
      if [ $? != 0 ]; then
        exit 1
      fi
    fi
  fi
done

echo "Installing pyenv..."
rm -rf ${HOME}/.pyenv
if uname -o |grep -i darwin; then
  brew install pyenv pyenv-virtualenv
else
  curl https://pyenv.run |bash
fi


if ! echo ${SHELL} |grep zsh >/dev/null 2>&1; then
  echo "Setting default shell to zsh..."
  sudo -u $USER chsh -s $(which zsh)
  echo "Please restart shell to switch to zsh and run this again..."
  exit 1
fi

# setup ssh key
git_identity_file="${HOME}/.ssh/identity.git"

if [ ! -f ${git_identity_file} ]; then
  echo "Generating ssh key for github into ${git_identity_file}"
  ssh-keygen -f ${git_identity_file}
  echo "Add this key to github before continuing: https://github.com/settings/keys"
  echo ""
  echo "$(cat ${git_identity_file}.pub)"
  exit 1
fi

echo "Removing old config..."
rm -rf $HOME/.cfg
alias config='git --git-dir=$HOME/.cfg/ --work-tree=$HOME'

if ! grep ".cfg" .gitignore >/dev/null 2>&1; then
  echo ".cfg" >> .gitignore
fi

echo "Starting ssh agent..."
keychain --nogui ~/.ssh/identity.git
source ~/.keychain/$(hostname)-sh

echo "Cloning dotfiles..."
git clone --bare git@github.com:DanTulovsky/dotfiles-config.git ${ZDOTDIR:-$HOME}/.cfg
config reset --hard HEAD
config config --local status.showUntrackedFiles no

# install zprezto
rm -rf ${ZDOTDIR:-$HOME}/.zprezto
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
