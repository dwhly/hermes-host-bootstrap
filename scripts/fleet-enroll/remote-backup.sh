#!/usr/bin/env bash
# remote-backup.sh <host> — runs ON the target as root. Protected pre-enrollment backup.
# Online SQLite snapshots (consistent while Hermes runs) + tar of the Hermes home and
# control files. Nothing is stopped or modified. Output dir is 0700, files 0600.
set -euo pipefail
host="$1"
HH="${HERMES_HOME_DIR:-$HOME/.hermes}"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
dir="/var/backups/hermes-fleet/${host}-enrollment-${ts}"
umask 077
need_kb=$(( $(du -sk "$HH" | awk '{print $1}') + 1048576 ))   # home size + 1 GiB margin
free_kb=$(df -Pk /var/backups 2>/dev/null | awk 'NR==2{print $4}' || df -Pk / | awk 'NR==2{print $4}')
(( free_kb > need_kb )) || { echo "not enough free disk for a safe backup (need ${need_kb} KB, have ${free_kb} KB)"; exit 1; }
mkdir -p "$dir/sqlite" "$dir/control"

# 1. online SQLite snapshots + integrity check
python3 - "$HH" "$dir/sqlite" <<'PY'
import sqlite3, sys, pathlib
home, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for db in sorted(list(home.glob("*.db")) + list(home.glob("*/*.db"))):
    dst = out / (str(db.relative_to(home)).replace("/", "__"))
    src = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    tgt = sqlite3.connect(dst)
    src.backup(tgt)
    ok = tgt.execute("pragma quick_check").fetchone()[0]
    tgt.close(); src.close()
    print(f"sqlite {db.relative_to(home)} -> {dst.name} quick_check={ok}")
    if ok != "ok":
        sys.exit(f"quick_check failed for {db}")
PY

# 2. Hermes home (minus live DBs, which are snapshotted above, and regenerable caches)
tar --warning=no-file-changed -C "$(dirname "$HH")" -cf "$dir/hermes-home.tar" \
  --exclude="$(basename "$HH")/*.db" --exclude="$(basename "$HH")/*.db-wal" \
  --exclude="$(basename "$HH")/*.db-shm" --exclude="$(basename "$HH")/*/*.db" \
  --exclude="$(basename "$HH")/cache" --exclude="$(basename "$HH")/image_cache" \
  --exclude="$(basename "$HH")/audio_cache" --exclude="$(basename "$HH")/node" \
  --exclude="$(basename "$HH")/models_dev_cache.json" \
  "$(basename "$HH")" || { rc=$?; (( rc == 1 )) || exit "$rc"; echo "note: some files changed while being archived (live Hermes); archive kept"; }

# 3. control-plane files that enrollment may touch
for f in /etc/hostname /etc/hosts /root/.ssh/authorized_keys /etc/chief/node.env \
         /etc/systemd/system/chief-node.service /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg; do
  [[ -e "$f" ]] && cp -a "$f" "$dir/control/$(echo "$f" | tr / _)"
done
crontab -l >"$dir/control/crontab.txt" 2>/dev/null || true
systemctl list-units --type=service --all --no-pager --no-legend >"$dir/control/services.txt" || true
ps -eo pid,lstart,cmd >"$dir/control/processes.txt"

# 4. manifest
( cd "$dir" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum ) >"$dir/MANIFEST.sha256"
chmod -R go-rwx "$dir"
echo "BACKUP_DIR=$dir"
du -sh "$dir" | awk '{print "BACKUP_SIZE=" $1}'
