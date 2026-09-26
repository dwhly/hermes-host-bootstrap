#!/bin/sh
# Run this reviewed script in a clean root shell AFTER verifying archive SHA256.
# argv is administrator-only, never a sudoers command or daemon entry point.
set -eu
umask 022
[ "$#" = 1 ] || { echo 'usage: install-archive.sh verified.tar' >&2; exit 2; }
archive=$1
stage=$(/usr/bin/mktemp -d /var/root-currency-step0.XXXXXX)
trap '/bin/rm -rf "$stage"' EXIT
/bin/chmod 0700 "$stage"
# --no-same-permissions is supported by GNU tar and macOS bsdtar. Do not use -p.
/usr/bin/tar --no-same-permissions -xf "$archive" -C "$stage"
# shellcheck source=hermes_converger/step0/trust.sh
. "$stage/hermes_converger/step0/trust.sh"
trusted_tree "$stage/hermes_converger"
for dir in /opt /opt/chief /opt/chief/bin /opt/chief/lib /opt/chief/lib/hermes-host-bootstrap; do
    if [ ! -e "$dir" ]; then /usr/bin/install -d -o root -m 0755 "$dir"; fi
    trusted_path "$dir"
done
# Copy the verified tree to the fixed root-owned home, avoiding /usr/local on
# Intel Homebrew Macs. Retain the previous payload for administrator inspection.
base=/opt/chief/lib/hermes-host-bootstrap
if [ -e "$base/hermes_converger" ]; then
    trusted_tree "$base/hermes_converger"
    previous=$(/usr/bin/mktemp -d "$base/previous.XXXXXX")
    /bin/mv "$base/hermes_converger" "$previous/"
fi
/bin/cp -R "$stage/hermes_converger" "$base/"
if [ -d /var/lib/chief/currency-step0 ]; then
    trusted_path /var/lib/chief/currency-step0
    /bin/rm -f /var/lib/chief/currency-step0/prepared /var/lib/chief/currency-step0/grants-removed
fi
/bin/sh "$base/hermes_converger/step0/close.sh"
