# RestoreStack

RestoreStack restores application configuration backups created by Media Stack Disaster Recovery. It discovers applications from [`danyeles/jenkins-infra`](https://github.com/danyeles/jenkins-infra), loads their configurations from [`danyeles/jenkins-shared-lib`](https://github.com/danyeles/jenkins-shared-lib), finds each application's host-side `/config` bind mount, and extracts the matching archive from `/mnt/Backups/apps`.

## Disaster recovery workflow

```text
Fresh server
     ↓
Install Docker
     ↓
Install Jenkins Bootstrap
     ↓
Run ArrSeed
     ↓
Run RestoreStack
     ↓
Deploy containers
     ↓
Media stack restored
```

RestoreStack restores configuration files; it does not install Docker, mount storage, or create containers. The `/mnt/Media` filesystem must already be mounted, and the backups must be available under `/mnt/Backups/apps`.

## Jenkins setup

1. Create a Jenkins Pipeline job pointing to this repository and its `Jenkinsfile`.
2. Ensure the Jenkins agent has Bash, Git, GNU tar, `mountpoint`, and [Mike Farah `yq` v4](https://github.com/mikefarah/yq) installed.
3. Ensure Jenkins can read both `https://github.com/danyeles/jenkins-infra` and `https://github.com/danyeles/jenkins-shared-lib`, access the backup and media mounts, and trigger the corresponding `deploy-<app>` jobs.
4. Run the `RestoreStack` pipeline. Leave `APP_NAME` empty to restore the full stack, or provide an app name from `apps.yaml` to restore only that application. Set `DRY_RUN` to preview the work without extracting archives or triggering deployment jobs.

The Jenkinsfile uses Jenkins' Pipeline `build` step to trigger each `deploy-<app>` job only after that application's restore succeeds. The Pipeline Build Step plugin must be available.

## Restore behavior

- `scripts/restore-stack.sh` clones the infrastructure repository and reads its `apps.yaml`, then clones the shared-library repository.
- For each app name in `apps.yaml`, the matching config YAML is loaded from `resources/configs/<app>.yaml` in the shared-library checkout. The script selects the unique volume ending in `:/config` or `:/app/config`; its host-side path is the restore target.
- Backup names normally match the app name. Exceptions: `qbittorrent-nox` uses the `qbittorrent` backup, `jellyfin` uses `jellyfin-full`, and `audiobookshelf` restores `audiobookshelf-config` followed by `audiobookshelf-metadata`. All configured backups must exist before extraction starts; a missing special backup marks that app `FAILED`.
- `qbittorrent-password`, `flaresolverr`, and `tdarr` are excluded from restore and reported as `SKIPPED`.
- A missing default `<app>/latest.tar.gz` is a warning and is reported as `SKIPPED`. Other per-app errors are reported as `FAILED`; processing continues for the remaining apps.
- The final console report contains `RESTORED`, `SKIPPED`, and `FAILED` sections. Jenkins deployment is started only for entries reported as `RESTORED`.
- Restore operations require `/mnt/Media` to be mounted and the backup directory to exist. Archives are checked for absolute and parent-traversal paths before extraction.
- Set `INFRA_BRANCH`, `INFRA_REPO_URL`, `SHARED_LIB_BRANCH`, `SHARED_LIB_REPO_URL`, `BACKUP_ROOT`, or `MEDIA_MOUNT` in Jenkins when your environment differs. The infrastructure branch defaults to `master`; when `SHARED_LIB_BRANCH` is unset, Git uses the shared library repository's default branch.

## Running from a shell

Run from a machine with the required mounts and tools:

```bash
DRY_RUN=true bash scripts/restore-stack.sh
APP_NAME=<app-name> bash scripts/restore-stack.sh
bash scripts/restore-stack.sh
```

The shell commands above are examples only; application names are discovered from `apps.yaml` and are not embedded in the implementation. `DRY_RUN` accepts `true` or `false` (case-insensitive). When set to true, potential restores appear in the `SKIPPED` section with a dry-run explanation.

To call the per-app helper directly, provide the app name and its config YAML from the shared-library repository. Optional backup names override the default `<app-name>` backup and are extracted in order:

```bash
bash scripts/restore-app.sh <app-name> <shared-lib-config-yaml> [backup-name ...]
```

The helper uses `BACKUP_ROOT` and `DRY_RUN` in the same way as the stack script. A missing backup exits with status 2; a dry-run preview exits with status 3; a successful extraction exits with status 0.
