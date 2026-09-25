#!/bin/zsh
# Read-only health check: monitor discovery, DDC, capabilities, config, KVM detection.
# Sends nothing to the monitor. Usage: scripts/check.sh
set -uo pipefail
# Use the kvmctl next to this script (release zip), else build it from source.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ -x "$HERE/kvmctl" ]]; then
  K="$HERE/kvmctl"
else
  cd "$HERE/.."
  K="$PWD/.build/release/kvmctl"
  [[ -x "$K" ]] || swift build -c release --product kvmctl >/dev/null
fi

step() { print "\n== $1"; }
step "Monitors";            "$K" monitor list
step "Capabilities";        "$K" monitor caps
step "Configured inputs";   "$K" monitor input list
step "Current input";       "$K" monitor input get
step "Config file";         CFG="$("$K" config path)"; [[ -f "$CFG" ]] && cat "$CFG" || print "missing: $CFG (run: $K config init)"
step "KVM detection (3 s)"
"$K" kvm watch &
PID=$!
sleep 3
kill $PID 2>/dev/null
wait $PID 2>/dev/null
print "\nDone. Nothing was sent to the monitor."
