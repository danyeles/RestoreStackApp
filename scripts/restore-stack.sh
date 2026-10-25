#!/usr/bin/env bash

# Discover applications from jenkins-infra and restore each app independently.
# A TSV report is written for Jenkins to decide which deployment jobs to start.
set -uo pipefail

log() {
    printf '[restore-stack] %s\n' "$*" >&2
}

fail() {
    log "ERROR: $*"
    exit 1
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
infra_repo_url=${INFRA_REPO_URL:-https://github.com/danyeles/jenkins-infra.git}
infra_branch=${INFRA_BRANCH:-master}
shared_lib_repo_url=${SHARED_LIB_REPO_URL:-https://github.com/danyeles/jenkins-shared-lib.git}
shared_lib_branch=${SHARED_LIB_BRANCH:-}
backup_root=${BACKUP_ROOT:-/mnt/Backups/apps}
media_mount=${MEDIA_MOUNT:-/mnt/Media}
app_filter=${APP_NAME:-}
skip_apps_input=${SKIP_APPS:-}
report_file=${RESTORE_REPORT:-}
dry_run=${DRY_RUN:-false}

case "${dry_run,,}" in
    true|1|yes) dry_run=true ;;
    false|0|no|"") dry_run=false ;;
    *) fail "DRY_RUN must be true or false (received: $dry_run)" ;;
esac

for utility in git mountpoint; do
    command -v "$utility" >/dev/null 2>&1 || fail "$utility is required"
done
command -v yq >/dev/null 2>&1 || fail "Mike Farah yq v4 is required to read YAML configuration"
[[ -f $script_dir/restore-app.sh && -r $script_dir/restore-app.sh ]] || fail "restore-app.sh is missing or unreadable"

# These global checks happen before any app is changed. restore-app.sh repeats
# them as well, so direct invocation of that helper remains safe.
mountpoint -q "$media_mount" || fail "$media_mount is not mounted"
[[ -d $backup_root && -r $backup_root ]] || fail "Backup storage is missing or unreadable: $backup_root"

if [[ -n $report_file ]]; then
    : > "$report_file" || fail "Unable to create restore report: $report_file"
fi

work_dir=$(mktemp -d) || fail "Unable to create temporary workspace"
cleanup() {
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

infra_dir="$work_dir/jenkins-infra"
if ! git clone --quiet --depth 1 --branch "$infra_branch" "$infra_repo_url" "$infra_dir"; then
    fail "Unable to clone $infra_repo_url (branch: $infra_branch)"
fi

apps_file="$infra_dir/apps.yaml"
[[ -f $apps_file && -r $apps_file ]] || fail "apps.yaml was not loaded from $infra_repo_url"
app_count=$(yq -r '.apps | length' "$apps_file") || fail "Unable to parse $apps_file"
[[ $app_count =~ ^[0-9]+$ ]] && (( app_count > 0 )) || fail "apps.yaml contains no applications"
log "Loaded $app_count applications from $apps_file"

app_rows=$(yq -r '.apps[] | .name' "$apps_file") || fail "Unable to read app entries from $apps_file"
[[ -n $app_rows ]] || fail "apps.yaml did not provide any app entries"

declare -A skip_app_map=()
if [[ -n $skip_apps_input ]]; then
    if [[ $skip_apps_input == ,* || $skip_apps_input == *, || $skip_apps_input == *,,* ]]; then
        fail "SKIP_APPS must be a comma-separated list of application names without empty entries"
    fi

    IFS=',' read -r -a requested_skip_apps <<< "$skip_apps_input"
    for skip_app in "${requested_skip_apps[@]}"; do
        skip_app="${skip_app#"${skip_app%%[![:space:]]*}"}"
        skip_app="${skip_app%"${skip_app##*[![:space:]]}"}"
        [[ -n $skip_app ]] || fail "SKIP_APPS contains an empty application name"
        [[ $skip_app =~ ^[A-Za-z0-9._-]+$ ]] || fail "Invalid application name in SKIP_APPS: $skip_app"

        app_found=false
        while IFS= read -r manifest_app; do
            if [[ $manifest_app == "$skip_app" ]]; then
                app_found=true
                break
            fi
        done <<< "$app_rows"
        [[ $app_found == true ]] || fail "SKIP_APPS application '$skip_app' was not found in apps.yaml"

        skip_app_map["$skip_app"]=1
    done
fi

shared_lib_dir="$work_dir/jenkins-shared-lib"
if [[ -n $shared_lib_branch ]]; then
    if ! git clone --quiet --depth 1 --branch "$shared_lib_branch" "$shared_lib_repo_url" "$shared_lib_dir"; then
        fail "Unable to clone $shared_lib_repo_url (branch: $shared_lib_branch)"
    fi
elif ! git clone --quiet --depth 1 "$shared_lib_repo_url" "$shared_lib_dir"; then
    fail "Unable to clone $shared_lib_repo_url"
fi

restored=()
skipped=()
failed=()
found_requested_app=false

record_result() {
    local status=$1
    local name=$2
    local detail=${3:-}

    case "$status" in
        RESTORED) restored+=("$name") ;;
        SKIPPED) skipped+=("$name${detail:+ ($detail)}") ;;
        FAILED) failed+=("$name${detail:+ ($detail)}") ;;
        *) fail "Internal error: invalid result status $status" ;;
    esac
    if [[ -n $report_file ]]; then
        printf '%s\t%s\n' "$status" "$name" >> "$report_file" || fail "Unable to update restore report: $report_file"
    fi
}

while IFS= read -r app_name; do
    [[ -n $app_name ]] || continue
    if [[ -n $app_filter && $app_name != "$app_filter" ]]; then
        continue
    fi
    found_requested_app=true

    case "$app_name" in
        qbittorrent-password|flaresolverr|tdarr)
            log "Skipping excluded application: $app_name"
            record_result SKIPPED "$app_name" "excluded from restore"
            continue
            ;;
    esac
    if [[ ${skip_app_map[$app_name]+selected} == selected ]]; then
        log "Skipping application selected in SKIP_APPS: $app_name"
        record_result SKIPPED "$app_name" "selected to skip"
        continue
    fi

    backup_names=("$app_name")
    special_backup=false
    case "$app_name" in
        qbittorrent-nox)
            backup_names=(qbittorrent)
            special_backup=true
            ;;
        jellyfin)
            backup_names=(jellyfin-full)
            special_backup=true
            ;;
        audiobookshelf)
            backup_names=(audiobookshelf-config audiobookshelf-metadata)
            special_backup=true
            ;;
    esac

    # App identifiers are validated before use to keep repository data bounded.
    if [[ ! $app_name =~ ^[A-Za-z0-9._-]+$ ]]; then
        log "ERROR: Invalid application name in apps.yaml: $app_name"
        record_result FAILED "$app_name" "invalid app name"
        continue
    fi
    config_file="$shared_lib_dir/resources/configs/$app_name.yaml"
    if [[ ! -f $config_file || ! -r $config_file ]]; then
        log "ERROR: Config file for $app_name is missing or unreadable: resources/configs/$app_name.yaml"
        record_result FAILED "$app_name" "config missing"
        continue
    fi
    log "Processing $app_name using resources/configs/$app_name.yaml"
    if BACKUP_ROOT="$backup_root" MEDIA_MOUNT="$media_mount" DRY_RUN="$dry_run" \
        bash "$script_dir/restore-app.sh" "$app_name" "$config_file" "${backup_names[@]}"; then
        record_result RESTORED "$app_name"
    else
        result=$?
        case $result in
            2)
                if [[ $special_backup == true ]]; then
                    record_result FAILED "$app_name" "configured backup missing"
                else
                    record_result SKIPPED "$app_name" "backup missing"
                fi
                ;;
            3) record_result SKIPPED "$app_name" "DRY_RUN: restore preview only" ;;
            *) record_result FAILED "$app_name" "restore exited with status $result" ;;
        esac
    fi
done <<< "$app_rows"

if [[ -n $app_filter && $found_requested_app != true ]]; then
    log "ERROR: APP_NAME '$app_filter' was not found in apps.yaml"
    record_result FAILED "$app_filter" "app not found in apps.yaml"
fi

print_section() {
    local heading=$1
    shift
    printf '\n%s\n' "$heading"
    if (( $# == 0 )); then
        printf '  (none)\n'
    else
        printf '  %s\n' "$@"
    fi
}

printf '\nRestoreStack final report\n'
print_section RESTORED "${restored[@]}"
print_section SKIPPED "${skipped[@]}"
print_section FAILED "${failed[@]}"

if (( ${#failed[@]} > 0 )); then
    exit 1
fi
