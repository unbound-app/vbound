#!/bin/zsh
state="$HOME/.local/state/vbound-vphone-running"
mkdir -p "${state:h}"
if /usr/bin/pgrep -if 'vphone-cli' >/dev/null; then
    if [[ ! -e "$state" ]]; then
        /usr/bin/touch "$state"
        /usr/bin/open -gj "$1"
    fi
else
    /bin/rm -f "$state"
fi
