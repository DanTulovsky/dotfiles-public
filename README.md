Run this first in a bash shell:

```
bash <(wget "https://raw.githubusercontent.com/DanTulovsky/dotfiles-public/main/setup_new.sh?token=$(date +%s)")
```

After switching to zsh, re-run this:

```
curl "https://raw.githubusercontent.com/DanTulovsky/dotfiles-public/main/setup_new.sh?token=$(date +%s)" |bash
```
