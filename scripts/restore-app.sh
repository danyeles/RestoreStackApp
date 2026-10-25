#!/usr/bin/env bash

# Restore one application's configuration archive into the host directory
# mapped to the container's /config path.
set -uo pipefail

log() {
    printf '[restore-app] %s\n' "$*" >&2
}

fail() {
    log "ERROR: $*"
    exit 1
}

if [[ $# -lt 2 ]]; then
    fail "Usage: $0 <app-name> <shared-lib-config-yaml> [backup-name ...]"
fi

app_name=$1
config_file=$2
shift 2
if (( $# == 0 )); then
    set -- "$app_name"
fi
backup_names=("$@")
backup_root=${BACKUP_ROOT:-/mnt/Backups/apps}
media_mount=${MEDIA_MOUNT:-/mnt/Media}
dry_run=${DRY_RUN:-false}

if [[ ! $app_name =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail "Invalid application name: $app_name"
fi

if [[ ! -f $config_file || ! -r $config_file ]]; then
    fail "Shared-library configuration file is missing or unreadable: $config_file"
fi

if ! command -v yq >/dev/null 2>&1; then
    fail "yq v4 is required to read application configuration"
fi

case "${dry_run,,}" in
    true|1|yes) dry_run=true ;;
    false|0|no|"") dry_run=false ;;
    *) fail "DRY_RUN must be true or false (received: $dry_run)" ;;
esac

# Refuse to restore when the media filesystem is absent; this catches a common
# recovery mistake where mount points exist but the intended storage is offline.
if ! command -v mountpoint >/dev/null 2>&1; then
    fail "mountpoint is required for the /mnt/Media safety check"
fi
if ! mountpoint -q "$media_mount"; then
    fail "$media_mount is not mounted"
fi

if [[ ! -d $backup_root || ! -r $backup_root ]]; then
    fail "Backup storage is missing or unreadable: $backup_root"
fi

# Only a single /config bind mount is safe to restore automatically. Reject
# ambiguous or relative paths instead of guessing which host directory to use.
volume_output=$(yq -r '.volumes[]? | select(tag == "!!str") | select(test(":/config$"))' "$config_file") \
    || fail "Unable to read volumes from $config_file"
mapfile -t config_mounts <<< "$volume_output"
if [[ -z $volume_output ]]; then
    config_mounts=()
fi
if [[ ${#config_mounts[@]} -ne 1 ]]; then
    fail "Expected exactly one volume ending in :/config in $config_file; found ${#config_mounts[@]}"
fi

config_mount=${config_mounts[0]}
target_dir=${config_mount%:/config}
if [[ -z $target_dir || $target_dir != /* || $target_dir == / ]]; then
    fail "The /config bind mount must have a non-root absolute host path: $config_mount"
fi

if ! command -v tar >/dev/null 2>&1; then
    fail "tar is required to extract application backups"
fi

archives=()
for backup_name in "${backup_names[@]}"; do
    if [[ ! $backup_name =~ ^[A-Za-z0-9._-]+$ ]]; then
        fail "Invalid backup name: $backup_name"
    fi
    archive="$backup_root/$backup_name/latest.tar.gz"
    if [[ ! -f $archive || ! -r $archive ]]; then
        log "WARNING: Backup is missing or unreadable; skipping $app_name ($archive)"
        exit 2
    fi

    # Validate every archive before extracting any, so a missing or unsafe
    # later archive cannot leave a partially restored application.
    archive_members=$(tar -tzf "$archive") || fail "Unable to read backup archive: $archive"
    while IFS= read -r member; do
        if [[ $member == /* || $member == .. || $member == ../* || $member == */../* || $member == */.. ]]; then
            fail "Unsafe path in backup archive: $member"
        fi
    done <<< "$archive_members"
    archives+=("$archive")
done

if [[ $dry_run == true ]]; then
    for archive in "${archives[@]}"; do
        log "DRY_RUN: would extract $archive into $target_dir"
    done
    exit 3
fi

mkdir -p -- "$target_dir" || fail "Unable to create restore target: $target_dir"
for archive in "${archives[@]}"; do
    tar --extract --gzip --file="$archive" --directory="$target_dir" \
        --no-same-owner --no-same-permissions \
        || fail "Extraction failed for $app_name from $archive"
done

log "Restored $app_name into $target_dir"
