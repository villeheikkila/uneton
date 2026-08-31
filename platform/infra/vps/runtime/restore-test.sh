#!/usr/bin/env sh
set -eu
cd /srv/uneton
data_dir=/var/lib/docker/volumes/uneton_uneton-data/_data
database="$data_dir/uneton.sqlite"
backup="$database.before-restore.$(date -u +%Y%m%dT%H%M%SZ)"
restore_complete=0

recover_on_failure() {
  status=$?
  trap - EXIT
  if [ "$restore_complete" -ne 1 ]; then
    if [ -f "$backup" ]; then
      rm -f "$database" "$database-shm" "$database-wal"
      mv "$backup" "$database"
    fi
    docker compose up -d api litestream >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap recover_on_failure EXIT

docker compose stop api litestream
test -f "$database"
test ! -e "$backup"
mv "$database" "$backup"
rm -f "$database-shm" "$database-wal"
docker run --rm \
  -v uneton_uneton-data:/data \
  -v uneton_uneton-backups:/backup \
  litestream/litestream:0.3 restore -o /data/uneton.sqlite file:///backup
chown --reference="$backup" "$database"
chmod --reference="$backup" "$database"
rm -f "$database.sync-generation"
rm -f "$database.tmp-shm" "$database.tmp-wal"
docker compose up -d api litestream
restore_complete=1
trap - EXIT
echo "Restored SQLite from the Litestream replica; pre-restore database remains at $backup"
