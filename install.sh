#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ "$#" -le 1 ] || { echo 'Usage: sh install.sh [built-MacUnlock.app]' >&2; exit 64; }
source_app=${1:-"$root/build/MacUnlock.app"}
target="$HOME/Applications/MacUnlock.app"
cli="$HOME/.local/bin/mac-unlock"
# Never silently replace an App identity, credential ACL or existing command.
if [ -e "$target" ] || [ -L "$target" ] || [ -e "$cli" ] || [ -L "$cli" ]; then
    echo 'Installation refused: App or command already exists. Review and back it up before a manual update; rebuilds require fresh OS authorization and may require masked setup again.' >&2
    exit 2
fi
[ "$(basename -- "$source_app")" = MacUnlock.app ] &&
[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$source_app/Contents/Info.plist" 2>/dev/null)" = com.example.MacUnlock ] || exit 2
/usr/bin/codesign --verify --deep --strict "$source_app"
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
/usr/bin/ditto "$source_app" "$target"
cp "$root/bin/mac-unlock" "$cli"
chmod 755 "$cli"
printf '%s\n' 'Installed MacUnlock.app and ~/.local/bin/mac-unlock. Configure permissions and masked setup yourself before unlocking.'
