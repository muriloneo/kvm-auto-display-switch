#!/bin/zsh
# Prints USB devices as they disappear/appear with their vendor and product IDs.
# Run it, press the KVM button a few times, then Ctrl+C. The devices that come and go
# together are the KVM's; put their IDs in the config's "kvm.usbDevices".
set -uo pipefail

snapshot() {
  ioreg -p IOUSB -l -w0 | awk '
    /\+-o / { if (name != "") print name " vendorId=" vid " productId=" pid; name=$0; sub(/.*\+-o /, "", name); sub(/@.*/, "", name); vid=""; pid="" }
    /"idVendor" =/  { vid=$NF }
    /"idProduct" =/ { pid=$NF }
    END { if (name != "") print name " vendorId=" vid " productId=" pid }' | grep -v "vendorId= " | sort
}

print "Watching USB devices. Press the KVM button, then Ctrl+C."
prev="$(snapshot)"
while true; do
  sleep 0.5
  cur="$(snapshot)"
  diff <(print -r -- "$prev") <(print -r -- "$cur") | grep '^[<>]' | sed "s/^</$(date +%T) REMOVED /;s/^>/$(date +%T) ADDED   /"
  prev="$cur"
done
