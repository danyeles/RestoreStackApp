pipeline {
    agent any

    options {
        timestamps()
    }

    parameters {
        string(
            name: 'APP_NAME',
            defaultValue: '',
            description: 'Application from apps.yaml to restore; leave empty to restore the full stack.'
        )
        string(
            name: 'SKIP_APPS',
            defaultValue: '',
            description: 'Comma-separated app names to skip during a full restore, for example: sonarr,radarr.'
        )
        booleanParam(
            name: 'DRY_RUN',
            defaultValue: false,
            description: 'Preview restores without extracting backups or deploying applications.'
        )
    }

    environment {
        RESTORE_REPORT = 'restore-report.tsv'
    }

    stages {
        stage('Restore application configuration') {
            steps {
                script {
                    def restoreStatus
                    withEnv(["SKIP_APPS=${params.SKIP_APPS ?: ''}"]) {
                        restoreStatus = sh(
                            returnStatus: true,
                            script: 'bash scripts/restore-stack.sh'
                        )
                    }
                    if (restoreStatus != 0) {
                        // Keep the deployment stage available so apps restored
                        // successfully can still be brought back online.
                        currentBuild.result = 'FAILURE'
                        echo "RestoreStack reported failures (exit ${restoreStatus}); continuing with successful restores."
                    }
                }
            }
        }

        stage('Deploy restored applications') {
            when {
                expression { !params.DRY_RUN }
            }
            steps {
                script {
                    if (!fileExists(env.RESTORE_REPORT)) {
                        error("Restore report was not created: ${env.RESTORE_REPORT}")
                    }

                    def restoredApps = readFile(env.RESTORE_REPORT)
                        .readLines()
                        .findAll { it.startsWith("RESTORED\t") }
                        .collect { it.split('\\t', 2)[1] }
                        .unique()

                    restoredApps.each { appName ->
                        // The app name is discovered from apps.yaml and checked
                        // by restore-stack.sh before it can appear in this report.
                        echo "Triggering deploy-${appName}"
                        build job: "deploy-${appName}", wait: false
                    }
                }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'restore-report.tsv', allowEmptyArchive: true
        }
    }
}
