// Build job for k8s microservices, supporting Prometheus Exporter, Operator
// Backup, CNG, Couchbase Converge, etc
//
// Builds PRODUCT from its source on latestbuilds and uploads the results
// to latestbuilds, then triggers couchbase-k8s-microservice-docker to
// build the images, and new-build-available.
//
// - Most products build on a couchbase-k8s-microservices label.
// - couchbase-converge products build on x86_64&&linux and aarch64&&linux labels.
// - Rust based couchbase-converge-mongodb can't be cross-compiled, so it
//   builds natively on x86_64 and aarch64 in parallel, then packages the
//   image tarball from both architectures' binaries.
//
// Builds of different PRODUCT/VERSION/BLD_NUMs run concurrently; a
// duplicate waits in the queue. Failures are emailed to build-team and
// posted to slack channels

// The agent labels to build PRODUCT on, one build per label
def buildLabels(String product) {
    switch (product) {
        case 'couchbase-converge-mongodb':
            return ['x86_64&&linux-small', 'aarch64&&linux-small']
        case ['couchbase-converge-cbcmsync', 'couchbase-converge-redis']:
            return ['x86_64&&linux-small']
        default:
            return ['couchbase-k8s-microservices']
    }
}

def isCargoProduct(String product) {
    return product == 'couchbase-converge-mongodb'
}

// Cleans the workspace and checks out build-tools into local-build-tools
def checkoutBuildTools() {
    cleanWs()
    dir('local-build-tools') {
        git url: "https://github.com/${params.BUILD_TOOLS_ORG}/build-tools", branch: 'master'
    }
}

// Uploads sourceFiles (relative to the workspace) from ${PRODUCT}/dist to
// latestbuilds. AWS agents (which have /aws, per CBD-4179) can't reach
// latestbuilds directly, so their files are published from the controller.
def uploadToLatestbuilds(String sourceFiles) {
    def onAws = sh(script: '[ -d /aws ]', returnStatus: true) == 0
    sshPublisher(
        alwaysPublishFromMaster: onAws,
        failOnError: true,
        publishers: [sshPublisherDesc(
            configName: 'latestbuilds',
            transfers: [sshTransfer(
                sourceFiles: sourceFiles,
                removePrefix: "${params.PRODUCT}/dist",
                remoteDirectory: "${params.PRODUCT}/${params.RELEASE}/${params.BLD_NUM}"
            )]
        )]
    )
}

// This build's parameters, for passing on to downstream jobs
def currentParameters() {
    return ['PRODUCT', 'RELEASE', 'VERSION', 'BLD_NUM', 'BUILD_TOOLS_ORG'].collect {
        string(name: it, value: params[it] ?: '')
    }
}

// Posts the build's result to Slack: operator products to the
// operator_build channel (CQ3KL6Y3Y), all other products to the
// build-alerts channel (C07B1DXKE75)
def notifySlack(String result, String color) {
    def channel = params.PRODUCT.contains('operator') ? 'CQ3KL6Y3Y' : 'C07B1DXKE75'
    slackSend teamDomain: 'couchbase',
              tokenCredentialId: 'jenkins-slackbot',
              botUser: true,
              channel: channel,
              color: color,
              message: "${env.JOB_NAME} - ${currentBuild.displayName} ${result} after ${currentBuild.durationString.replace(' and counting', '')} (<${env.BUILD_URL}|Open>)"
}

pipeline {
    agent none

    options {
        buildDiscarder(logRotator(numToKeepStr: '100'))
        timestamps()
        // Builds of different PRODUCT/VERSION/BLD_NUMs run concurrently; a
        // build of the same one waits in the queue for the running one
        throttleJobProperty(
            throttleEnabled: true,
            throttleOption: 'project',
            categories: [],
            maxConcurrentPerNode: 0,
            maxConcurrentTotal: 0,
            limitOneJobWithMatchingParams: true,
            paramsToUseForLimit: 'PRODUCT,VERSION,BLD_NUM'
        )
    }

    parameters {
        string(name: 'PRODUCT', defaultValue: '', description: '')
        string(name: 'RELEASE', defaultValue: '', description: '')
        string(name: 'VERSION', defaultValue: '', description: '')
        string(name: 'BLD_NUM', defaultValue: '', description: 'Release build number (passed in by trigger job)')
        string(name: 'BUILD_TOOLS_ORG', defaultValue: 'couchbase', description: 'Do not change this unless you are debugging fixes to k8s build process!')
    }

    stages {
        stage('Setup') {
            steps {
                script {
                    currentBuild.displayName = "${params.PRODUCT}-${params.VERSION}-${params.BLD_NUM}"
                }
            }
        }

        stage('Build') {
            steps {
                script {
                    parallel buildLabels(params.PRODUCT).collectEntries { label ->
                        [(label): {
                            node(label) {
                                checkoutBuildTools()
                                sh 'local-build-tools/xshell/download_build_source'
                                if (isCargoProduct(params.PRODUCT)) {
                                    sh 'local-build-tools/k8s-microservice/jenkins/couchbase-k8s-microservice-cargo-build.sh build'
                                } else {
                                    sh 'local-build-tools/k8s-microservice/jenkins/couchbase-k8s-microservice-build.sh'
                                }
                                if (params.PRODUCT == 'couchbase-operator') {
                                    // macOS binaries aren't "finished" yet - need to be codesigned/notarized
                                    sh '''
                                        cd couchbase-operator/dist
                                        mkdir unfinished
                                        mv *kubernetes-macos* *openshift-macos* unfinished
                                    '''
                                }
                                uploadToLatestbuilds("${params.PRODUCT}/dist/**/*")
                            }
                        }]
                    }
                }
            }
        }

        stage('Release binaries to S3 Staging') {
            when {
                expression { params.PRODUCT == 'couchbase-cloud-native-gateway' }
            }
            steps {
                build job: 'release_binaries_to_s3', wait: false, parameters: currentParameters() + [
                    booleanParam(name: 'PUSH_TO_LIVE', value: false),
                    string(name: 'COMMUNITY', value: 'none'),
                    string(name: 'SUFFIX', value: params.BLD_NUM),
                    string(name: 'APPROVAL_ISSUE', value: '')
                ]
            }
        }

        // Runs after every architecture's binary is on latestbuilds, as
        // packaging downloads them all
        stage('Package') {
            when {
                expression { isCargoProduct(params.PRODUCT) }
            }
            agent {
                label 'x86_64&&linux-small'
            }
            steps {
                checkoutBuildTools()
                sh 'local-build-tools/xshell/download_build_source'
                sh 'local-build-tools/k8s-microservice/jenkins/couchbase-k8s-microservice-cargo-build.sh package'
                uploadToLatestbuilds("${params.PRODUCT}/dist/*.tgz")
            }
        }
    }

    post {
        success {
            build job: 'couchbase-k8s-microservice-docker', wait: false, parameters: currentParameters()
            build job: 'new-build-available', wait: false, parameters: currentParameters()
        }
        failure {
            mail to: 'build-team@couchbase.com',
                 subject: "Build failed: ${env.JOB_NAME} ${currentBuild.displayName}",
                 body: "${env.BUILD_URL}"
            notifySlack('Failure', 'danger')
        }
        unstable {
            mail to: 'build-team@couchbase.com',
                 subject: "Build unstable: ${env.JOB_NAME} ${currentBuild.displayName}",
                 body: "${env.BUILD_URL}"
        }
        fixed {
            mail to: 'build-team@couchbase.com',
                 subject: "Build is back to normal: ${env.JOB_NAME} ${currentBuild.displayName}",
                 body: "${env.BUILD_URL}"
            notifySlack('Back to normal', 'good')
        }
    }
}
