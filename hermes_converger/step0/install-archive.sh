#!/bin/sh
# Run a private root-owned copy of this script AFTER pinning its own SHA256.
# argv is administrator-only, never a sudoers command or daemon entry point.
set -eu
umask 077
[ "$#" = 2 ] || { echo 'usage: install-archive.sh archive.tar expected-sha256' >&2; exit 2; }
archive=$1
expected=$2
case "$expected" in ''|*[!0-9a-f]*) exit 2;; esac
[ "${#expected}" = 64 ] || exit 2
case "$(/usr/bin/uname -s)" in
    Darwin) private=/var/root;;
    Linux) private=/root;;
    *) echo 'unsupported platform' >&2; exit 1;;
esac
stage=$(/usr/bin/mktemp -d "$private/currency-step0.XXXXXX")
trap '/bin/rm -rf "$stage"' EXIT
/bin/chmod 0700 "$stage"
# Copy before hashing: the transfer account may replace the source at any time.
# Neither tar nor imported code ever reads that source after this copy.
/bin/cp "$archive" "$stage/payload.tar"
if [ -x /usr/bin/shasum ]; then
    actual=$(/usr/bin/shasum -a 256 "$stage/payload.tar")
else
    actual=$(/usr/bin/sha256sum "$stage/payload.tar")
fi
[ "${actual%% *}" = "$expected" ] || { echo 'archive digest mismatch' >&2; exit 1; }
umask 022
# --no-same-permissions is supported by GNU tar and macOS bsdtar. Do not use -p.
/usr/bin/tar --no-same-permissions -xf "$stage/payload.tar" -C "$stage"
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
