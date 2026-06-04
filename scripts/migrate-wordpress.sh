#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: migrate-wordpress.sh --initial|--final [--dry-run]

Required environment:
  SOURCE_SSH              source SSH target, e.g. old.example.com or user@old.example.com
  DEST_SSH                destination SSH target, e.g. root@new.example.com
  SOURCE_PATH             source WordPress document root
  DEST_PATH               destination WordPress document root
  SOURCE_DB_NAME          source database name
  SOURCE_DB_USER          source database user
  SOURCE_DB_PASSWORD      source database password
  DEST_DB_NAME            destination database name
  DEST_DB_USER            destination database user
  DEST_DB_PASSWORD        destination database password

Optional environment:
  DEST_SSH_PRIVATE_KEY_FILE
                          private key file for destination SSH
  DEST_SSH_PUBLIC_KEY_FILE
                          public key file expected to match destination SSH key
  DEST_SSH_KNOWN_HOSTS_FILE
                          known_hosts file for destination SSH
  DEST_SSH_STRICT_HOST_KEY_CHECKING
                          destination host key policy, default accept-new
  SOURCE_DB_HOST          source database host, default localhost
  DEST_DB_HOST            destination database host, default localhost
  SOURCE_PUBLIC_URL       old URL for WP-CLI search-replace
  DEST_PUBLIC_URL         new URL for WP-CLI search-replace
  REMOTE_BACKUP_DIR       destination backup directory, default /srv/wordpress/backups
  RSYNC_EXTRA_ARGS        extra rsync args

The destination server pulls files from the source with SSH agent forwarding, so
your local SSH agent must be able to authenticate to the source host.
USAGE
}

quote() {
  printf "%q" "$1"
}

dest_ssh_args=()
verify_dest_ssh_key_pair() {
  if [[ -z "${DEST_SSH_PRIVATE_KEY_FILE:-}" || -z "${DEST_SSH_PUBLIC_KEY_FILE:-}" ]]; then
    return
  fi

  local derived_public_key configured_public_key
  derived_public_key="$(ssh-keygen -y -f "$DEST_SSH_PRIVATE_KEY_FILE" | awk '{ print $1 " " $2 }')"
  configured_public_key="$(awk '{ print $1 " " $2 }' "$DEST_SSH_PUBLIC_KEY_FILE")"
  if [[ "$derived_public_key" != "$configured_public_key" ]]; then
    echo "DEST_SSH_PUBLIC_KEY_FILE does not match DEST_SSH_PRIVATE_KEY_FILE." >&2
    exit 2
  fi
}

build_dest_ssh_args() {
  dest_ssh_args=()

  if [[ -n "${DEST_SSH_PRIVATE_KEY_FILE:-}" ]]; then
    dest_ssh_args+=(-i "$DEST_SSH_PRIVATE_KEY_FILE" -o IdentitiesOnly=yes)
  fi

  if [[ -n "${DEST_SSH_KNOWN_HOSTS_FILE:-}" ]]; then
    dest_ssh_args+=(-o "UserKnownHostsFile=$DEST_SSH_KNOWN_HOSTS_FILE")
  fi

  dest_ssh_args+=(-o "StrictHostKeyChecking=${DEST_SSH_STRICT_HOST_KEY_CHECKING:-accept-new}")
}

dest_ssh() {
  ssh "${dest_ssh_args[@]}" "$DEST_SSH" "$@"
}

dest_ssh_agent() {
  ssh -A "${dest_ssh_args[@]}" "$DEST_SSH" "$@"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 2
  fi
}

mode=""
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --initial)
      mode="initial"
      ;;
    --final)
      mode="final"
      ;;
    --dry-run)
      dry_run=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

if [[ -z "$mode" ]]; then
  usage
  exit 2
fi

for name in SOURCE_SSH DEST_SSH SOURCE_PATH DEST_PATH SOURCE_DB_NAME SOURCE_DB_USER SOURCE_DB_PASSWORD DEST_DB_NAME DEST_DB_USER DEST_DB_PASSWORD; do
  require_env "$name"
done

verify_dest_ssh_key_pair
build_dest_ssh_args

SOURCE_DB_HOST="${SOURCE_DB_HOST:-localhost}"
DEST_DB_HOST="${DEST_DB_HOST:-localhost}"
REMOTE_BACKUP_DIR="${REMOTE_BACKUP_DIR:-/srv/wordpress/backups}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
dump_name="wordpress-${mode}-${timestamp}.sql.gz"
remote_dump="${REMOTE_BACKUP_DIR}/${dump_name}"
rsync_dry_run=()
if [[ "$dry_run" -eq 1 ]]; then
  rsync_dry_run+=(--dry-run)
fi

dest_ssh "mkdir -p $(quote "$DEST_PATH") $(quote "$REMOTE_BACKUP_DIR")"

if [[ "$mode" == "final" && "$dry_run" -eq 0 ]]; then
  ssh "$SOURCE_SSH" "cd $(quote "$SOURCE_PATH") && wp maintenance-mode activate --allow-root || true"
fi

dest_ssh_agent \
  "rsync -azH --numeric-ids --delete --info=progress2 ${RSYNC_EXTRA_ARGS:-} ${rsync_dry_run[*]} -e 'ssh -o StrictHostKeyChecking=accept-new' $(quote "${SOURCE_SSH}:${SOURCE_PATH}/") $(quote "${DEST_PATH}/")"

if [[ "$dry_run" -eq 0 ]]; then
  ssh "$SOURCE_SSH" \
    "MYSQL_PWD=$(quote "$SOURCE_DB_PASSWORD") mysqldump --single-transaction --quick --hex-blob -h $(quote "$SOURCE_DB_HOST") -u $(quote "$SOURCE_DB_USER") $(quote "$SOURCE_DB_NAME") | gzip -c" \
    | dest_ssh "cat > $(quote "$remote_dump")"

  dest_ssh \
    "gzip -dc $(quote "$remote_dump") | MYSQL_PWD=$(quote "$DEST_DB_PASSWORD") mysql -h $(quote "$DEST_DB_HOST") -u $(quote "$DEST_DB_USER") $(quote "$DEST_DB_NAME")"

  if [[ -n "${SOURCE_PUBLIC_URL:-}" && -n "${DEST_PUBLIC_URL:-}" && "$SOURCE_PUBLIC_URL" != "$DEST_PUBLIC_URL" ]]; then
    dest_ssh \
      "cd $(quote "$DEST_PATH") && wp search-replace $(quote "$SOURCE_PUBLIC_URL") $(quote "$DEST_PUBLIC_URL") --all-tables --precise --skip-columns=guid --allow-root"
  fi

  dest_ssh "cd $(quote "$DEST_PATH") && wp cache flush --allow-root || true"
fi

if [[ "$mode" == "final" && "$dry_run" -eq 0 ]]; then
  dest_ssh "cd $(quote "$DEST_PATH") && wp maintenance-mode deactivate --allow-root || true"
fi

echo "Migration ${mode} pass complete. Database backup on destination: ${remote_dump}"
