#!/bin/zsh
# Builds the app and installs it to ~/Applications, replacing and relaunching any running copy.
set -euo pipefail
BUILT="$("$(dirname "$0")/bundle-app.sh")"
APP="$HOME/Applications/KVM Switcher.app"
osascript -e 'tell application id "local.kvm-switcher" to quit' 2>/dev/null || true
mkdir -p "$HOME/Applications"
ditto "$BUILT" "$APP"
echo "Installed $APP"
open "$APP"
