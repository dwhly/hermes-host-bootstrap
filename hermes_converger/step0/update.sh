#!/bin/sh
# Administrator-only replacement for chief-update. Never granted NOPASSWD.
set -eu
BASE=/opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0
# shellcheck source=hermes_converger/step0/trust.sh
. "$BASE/trust.sh"
OS=$(/usr/bin/uname -s)
trusted_path /opt/chief/lib
GIT=/usr/bin/git
if [ "$OS" = Darwin ]; then
    GIT=/Library/Developer/CommandLineTools/usr/bin/git
    trusted_tree /Library/Developer/CommandLineTools/usr/libexec/git-core
fi
trusted_path "$GIT"
trusted_path /etc/chief/.git-fleet-credentials
stage=$(/usr/bin/mktemp -d /opt/chief/lib/.chief-update.XXXXXX)
trap '/bin/rm -rf "$stage"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
# A fresh root checkout avoids retained hooks/config/alternates. Origin and ref
# are fixed; no caller flags or source checkout influence the installation.
"$GIT" -c core.hooksPath=/dev/null -c credential.helper= \
    -c 'credential.https://github.com.helper=store --file=/etc/chief/.git-fleet-credentials' \
    clone --quiet --depth=1 --branch main --single-branch \
    https://github.com/dwhly/hermes-host-bootstrap.git "$stage/src"
trusted_tree "$stage/src/hermes_converger"
trusted_path /opt/chief/lib/hermes-host-bootstrap
/bin/mv /opt/chief/lib/hermes-host-bootstrap/hermes_converger "$stage/previous"
if ! /bin/mv "$stage/src/hermes_converger" /opt/chief/lib/hermes-host-bootstrap/hermes_converger; then
    /bin/mv "$stage/previous" /opt/chief/lib/hermes-host-bootstrap/hermes_converger
    hold package_install_failed
    exit 1
fi
# close.sh (not a broader bootstrap module) restores the install/config contract,
# switches safe jobs and revokes grants last, including on preparation failure.
/bin/rm -f /var/lib/chief/currency-step0/prepared /var/lib/chief/currency-step0/grants-removed
/bin/sh "$BASE/close.sh"
