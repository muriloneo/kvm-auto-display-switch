#!/bin/zsh
# Finds the VCP 0x60 values your monitor really uses (many ignore the MCCS values they advertise).
# Sends one value at a time; you note what the monitor shows. If it leaves the Mac's input,
# bring it back with the monitor's buttons (most monitors ignore DDC from an inactive input).
# Usage: scripts/find-inputs.sh [values...]   default: 0x01..0x12 and 0x1B
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

values=("$@")
(( ${#values} )) || values=(0x01 0x02 0x03 0x04 0x05 0x06 0x07 0x08 0x09 0x0A 0x0B 0x0C 0x0D 0x0E 0x0F 0x10 0x11 0x12 0x1B)

print "Advertised by the monitor (may be wrong):"
"$K" monitor caps | grep "VCP 0x60"
print "\nKeep this Terminal on the Mac's built-in screen. Have the other computer awake."
for v in $values; do
  read "?Press Enter to send $v (Ctrl+C to stop) "
  "$K" monitor input send "$v"
  print "  -> Note what the monitor shows now. If it left the Mac, switch back with its buttons.\n"
done
