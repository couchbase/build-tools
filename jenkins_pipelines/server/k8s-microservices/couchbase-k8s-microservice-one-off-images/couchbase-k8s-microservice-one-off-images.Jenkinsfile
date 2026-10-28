// One-off image tarball job for k8s microservices
//
// Dumps a build's pre-GA multi-arch images from ghcr.io to OCI archive
// tarballs with create-one-off-image-tar.sh, one per registry the product
// publishes to (dockerhub and/or rhcc, per products-without-images.json),
// and uploads them with their .sha256 files to
// s3://packages.couchbase.com/releases/PRODUCT
//
// The tarballs are named after the images' public names, eg.
// couchbase-converge-redis_0.9.0-linux-rhcc.tar loads as
// registry.connect.redhat.com/couchbase/couchbase-converge-redis:0.9.0.

// Cleans the workspace and checks out build-tools into local-build-tools
def checkoutBuildTools() {
    cleanWs()
    dir('local-build-tools') {
        git url: "https://github.com/${params.BUILD_TOOLS_ORG}/build-tools", branch: 'master'
    }
}

// The registries (dockerhub, rhcc) PRODUCT publishes images to. funclib.sh
// needs bash, which sh steps don't run by default.
def imageRegistries(String product) {
    return ['dockerhub', 'rhcc'].findAll { registry ->
        sh(returnStatus: true, script: """#!/bin/bash
            source local-build-tools/k8s-microservice/jenkins/util/funclib.sh
            product_publishes_to '${product}' ${registry}
        """) == 0
    }
}

pipeline {
    agent {
        label 'couchbase-k8s-microservices'
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '100'))
        timestamps()
    }

    parameters {
        string(name: 'PRODUCT', defaultValue: '', description: 'eg. couchbase-converge-redis', trim: true)
        string(name: 'VERSION', defaultValue: '', description: 'eg. 0.9.0', trim: true)
        string(name: 'BLD_NUM', defaultValue: '', description: 'Build number of the images to dump', trim: true)
        string(name: 'SUFFIX', defaultValue: '', description: 'Optional suffix for the public tag, eg. beta gives VERSION-beta', trim: true)
        string(name: 'BUILD_TOOLS_ORG', defaultValue: 'couchbase', description: 'Do not change this unless you are debugging fixes to k8s build process!', trim: true)
    }

    stages {
        stage('Setup') {
            steps {
                script {
                    ['PRODUCT', 'VERSION', 'BLD_NUM'].each {
                        if (!params[it]) {
                            error "${it} is required"
                        }
                    }
                    currentBuild.displayName = "${params.PRODUCT}-${params.VERSION}-${params.BLD_NUM}"
                    if (params.SUFFIX) {
                        currentBuild.displayName += " (${params.SUFFIX})"
                    }
                }
                checkoutBuildTools()
            }
        }

        stage('Create and publish tarballs') {
            steps {
                script {
                    def registries = imageRegistries(params.PRODUCT)
                    if (!registries) {
                        error "${params.PRODUCT} has no images"
                    }
                    def suffixArg = params.SUFFIX ? "-x '${params.SUFFIX}'" : ''
                    registries.each { registry ->
                        stage(registry) {
                            sh """
                                local-build-tools/k8s-microservice/jenkins/create-one-off-image-tar.sh \
                                    -p '${params.PRODUCT}' -v '${params.VERSION}' -b '${params.BLD_NUM}' \
                                    -r ${registry} ${suffixArg} -P
                            """
                        }
                    }
                }
            }
        }
    }

    post {
        // Failures go to the build-alerts Slack channel (C07B1DXKE75)
        failure {
            slackSend teamDomain: 'couchbase',
                      tokenCredentialId: 'jenkins-slackbot',
                      botUser: true,
                      channel: 'C07B1DXKE75',
                      color: 'danger',
                      message: "${env.JOB_NAME} - ${currentBuild.displayName} Failure after ${currentBuild.durationString.replace(' and counting', '')} (<${env.BUILD_URL}|Open>)"
        }
        // The tarballs can be large; don't leave them on the agent, except
        // after a failure, to debug it
        cleanup {
            cleanWs(cleanWhenFailure: false)
        }
    }
}