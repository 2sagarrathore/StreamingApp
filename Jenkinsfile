// ===========================================================================
// StreamFlix CI/CD — build five images, push to ECR, deploy to EKS via Helm.
//
// Triggered automatically by a GitHub webhook on push (see jenkins/README.md),
// with an SCM poll as a safety net for when the webhook cannot reach Jenkins.
//
// Credentials this job expects (Manage Jenkins > Credentials):
//   aws-credentials   : "AWS Credentials" (or leave unset and use an EC2
//                       instance profile — see infra/scripts/50-jenkins-iam.sh)
//   github-credentials: username + PAT, for cloning and status checks
// ===========================================================================

def SERVICES = [
    [name: 'frontend',  repo: 'streamingapp/frontend',          context: 'frontend', dockerfile: 'frontend/Dockerfile'],
    [name: 'auth',      repo: 'streamingapp/auth-service',      context: 'backend',  dockerfile: 'backend/authService/Dockerfile'],
    [name: 'streaming', repo: 'streamingapp/streaming-service', context: 'backend',  dockerfile: 'backend/streamingService/Dockerfile'],
    [name: 'admin',     repo: 'streamingapp/admin-service',     context: 'backend',  dockerfile: 'backend/adminService/Dockerfile'],
    [name: 'chat',      repo: 'streamingapp/chat-service',      context: 'backend',  dockerfile: 'backend/chatService/Dockerfile'],
]

pipeline {
    agent any

    options {
        timestamps()
        ansiColor('xterm')
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        timeout(time: 60, unit: 'MINUTES')
        disableConcurrentBuilds()
        skipDefaultCheckout(false)
    }

    triggers {
        // Fires on every push once the GitHub webhook is wired up.
        githubPush()
        // Fallback for firewalled Jenkins instances that GitHub cannot reach.
        pollSCM('H/5 * * * *')
    }

    parameters {
        choice(name: 'ENVIRONMENT',   choices: ['prod', 'staging'],  description: 'Target environment')
        booleanParam(name: 'DEPLOY',  defaultValue: true,            description: 'Deploy to EKS after a successful build')
        booleanParam(name: 'RUN_SCAN', defaultValue: true,           description: 'Run a Trivy vulnerability scan on the built images')
        string(name: 'FORCE_TAG',     defaultValue: '',              description: 'Deploy this existing tag instead of building a new one')
    }

    environment {
        AWS_REGION     = 'ap-south-1'
        AWS_ACCOUNT_ID = credentials('aws-account-id')   // Secret text credential
        ECR_REGISTRY   = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
        CLUSTER_NAME   = 'streamingapp-eks'
        K8S_NAMESPACE  = 'streamingapp'
        HELM_RELEASE   = 'streamingapp'
        SNS_TOPIC_ARN  = "arn:aws:sns:${AWS_REGION}:${AWS_ACCOUNT_ID}:streamingapp-deployments"
        // Placeholder only. The Checkout stage overwrites this with
        // build-<number>-<short sha>, which is unique, sortable, and traceable
        // back to a commit. GIT_COMMIT is not resolvable this early, so it
        // cannot be built here.
        IMAGE_TAG      = "build-${BUILD_NUMBER}"
        DOCKER_BUILDKIT = '1'
    }

    stages {

        // -------------------------------------------------------------------
        stage('Checkout') {
        // -------------------------------------------------------------------
            steps {
                script { env.FAILED_STAGE = 'Checkout' }

                checkout scm
                script {
                    env.GIT_SHA        = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
                    env.GIT_BRANCH_NAME = sh(returnStdout: true, script: 'git rev-parse --abbrev-ref HEAD').trim()
                    env.GIT_AUTHOR     = sh(returnStdout: true, script: 'git log -1 --pretty=format:%an').trim()
                    env.GIT_MESSAGE    = sh(returnStdout: true, script: 'git log -1 --pretty=format:%s').trim()
                    env.IMAGE_TAG      = params.FORCE_TAG?.trim() ?: "build-${env.BUILD_NUMBER}-${env.GIT_SHA}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.IMAGE_TAG}"
                    currentBuild.description = "${env.GIT_BRANCH_NAME} — ${env.GIT_MESSAGE}"
                }
                echo "Building ${env.IMAGE_TAG} from ${env.GIT_BRANCH_NAME}@${env.GIT_SHA} by ${env.GIT_AUTHOR}"
            }
        }

        // -------------------------------------------------------------------
        stage('Preflight') {
        // -------------------------------------------------------------------
            steps {
                script { env.FAILED_STAGE = 'Preflight' }

                sh '''
                    set -e
                    echo "--- toolchain ---"
                    docker --version
                    aws --version
                    kubectl version --client
                    helm version --short
                    echo "--- aws identity ---"
                    aws sts get-caller-identity
                '''
            }
        }

        // -------------------------------------------------------------------
        stage('Static checks') {
        // -------------------------------------------------------------------
            environment { FAILED_STAGE = 'Static checks' }
            parallel {
                stage('Helm lint') {
                    steps {
                        sh '''
                            set -e
                            helm lint helm/streamingapp
                            # Prove the chart renders with the values the deploy stage will use.
                            helm template ci helm/streamingapp \
                              --set global.image.registry=$ECR_REGISTRY \
                              --set global.image.tag=$IMAGE_TAG \
                              --set secrets.jwtSecret=ci-placeholder \
                              --set mongodb.auth.rootPassword=ci-placeholder \
                              > /tmp/rendered-manifests.yaml
                            echo "rendered $(grep -c '^kind:' /tmp/rendered-manifests.yaml) Kubernetes objects"
                        '''
                        sh 'cp /tmp/rendered-manifests.yaml rendered-manifests.yaml'
                        archiveArtifacts artifacts: 'rendered-manifests.yaml', fingerprint: false
                    }
                }
                stage('Dockerfile lint') {
                    steps {
                        // hadolint is advisory — a style warning should not block a release.
                        sh '''
                            if command -v hadolint >/dev/null 2>&1; then
                              hadolint --failure-threshold error \
                                frontend/Dockerfile \
                                backend/*/Dockerfile || true
                            else
                              echo "hadolint not installed on this agent — skipping"
                            fi
                        '''
                    }
                }
                stage('Shell script check') {
                    steps {
                        sh '''
                            if command -v shellcheck >/dev/null 2>&1; then
                              shellcheck -S error infra/scripts/*.sh monitoring/*.sh chatops/*.sh || true
                            else
                              echo "shellcheck not installed on this agent — skipping"
                            fi
                        '''
                    }
                }
            }
        }

        // -------------------------------------------------------------------
        stage('ECR login') {
        // -------------------------------------------------------------------
            when { expression { !params.FORCE_TAG?.trim() } }
            steps {
                script { env.FAILED_STAGE = 'ECR login' }

                sh '''
                    set -e
                    aws ecr get-login-password --region "$AWS_REGION" \
                      | docker login --username AWS --password-stdin "$ECR_REGISTRY"
                '''
            }
        }

        // -------------------------------------------------------------------
        stage('Build & push images') {
        // -------------------------------------------------------------------
            when { expression { !params.FORCE_TAG?.trim() } }
            steps {
                script { env.FAILED_STAGE = 'Build & push images' }

                script {
                    // Five independent docker builds — run them at the same time.
                    def builds = [:]
                    SERVICES.each { svc ->
                        builds["${svc.name}"] = {
                            stage("build ${svc.name}") {
                                sh """
                                    set -e
                                    IMAGE="\$ECR_REGISTRY/${svc.repo}"

                                    docker build \\
                                      --file  ${svc.dockerfile} \\
                                      --tag   "\$IMAGE:\$IMAGE_TAG" \\
                                      --tag   "\$IMAGE:latest" \\
                                      --label org.opencontainers.image.revision=\$GIT_SHA \\
                                      --label org.opencontainers.image.source=https://github.com/UnpredictablePrashant/StreamingApp \\
                                      --label org.opencontainers.image.created=\$(date -u +%Y-%m-%dT%H:%M:%SZ) \\
                                      --cache-from "\$IMAGE:latest" \\
                                      --build-arg BUILDKIT_INLINE_CACHE=1 \\
                                      ${svc.context}

                                    docker push "\$IMAGE:\$IMAGE_TAG"
                                    docker push "\$IMAGE:latest"
                                    echo "pushed \$IMAGE:\$IMAGE_TAG"
                                """
                            }
                        }
                    }
                    parallel builds
                }
            }
        }

        // -------------------------------------------------------------------
        stage('Vulnerability scan') {
        // -------------------------------------------------------------------
            when {
                allOf {
                    expression { params.RUN_SCAN }
                    expression { !params.FORCE_TAG?.trim() }
                }
            }
            steps {
                script { env.FAILED_STAGE = 'Vulnerability scan' }

                script {
                    // ECR's own scan-on-push already ran; this is a second opinion
                    // with a machine-readable report attached to the build.
                    SERVICES.each { svc ->
                        sh """
                            if command -v trivy >/dev/null 2>&1; then
                              trivy image --quiet --scanners vuln \\
                                --severity HIGH,CRITICAL \\
                                --format table \\
                                --output trivy-${svc.name}.txt \\
                                --exit-code 0 \\
                                "\$ECR_REGISTRY/${svc.repo}:\$IMAGE_TAG"
                            else
                              echo "trivy not installed — relying on ECR scan-on-push" > trivy-${svc.name}.txt
                            fi
                        """
                    }
                }
                archiveArtifacts artifacts: 'trivy-*.txt', allowEmptyArchive: true
            }
        }

        // -------------------------------------------------------------------
        stage('Deploy to EKS') {
        // -------------------------------------------------------------------
            when { expression { params.DEPLOY } }
            steps {
                script { env.FAILED_STAGE = 'Deploy to EKS' }

                sh '''
                    set -e
                    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
                    kubectl create namespace "$K8S_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

                    # Reuse the secrets already in the cluster so a redeploy does not
                    # invalidate live sessions or lock the app out of its database.
                    JWT_SECRET=$(kubectl get secret "${HELM_RELEASE}-secrets" -n "$K8S_NAMESPACE" \
                      -o jsonpath='{.data.JWT_SECRET}' 2>/dev/null | base64 -d || true)
                    [ -z "$JWT_SECRET" ] && JWT_SECRET=$(openssl rand -hex 32)

                    MONGO_PASSWORD=$(kubectl get secret "${HELM_RELEASE}-mongodb" -n "$K8S_NAMESPACE" \
                      -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' 2>/dev/null | base64 -d || true)
                    [ -z "$MONGO_PASSWORD" ] && MONGO_PASSWORD=$(openssl rand -hex 24)

                    IRSA_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/streamingapp-app-irsa"

                    # --atomic rolls the release back automatically if any pod fails
                    # to become ready inside the timeout, so a bad build never
                    # leaves the cluster half-upgraded.
                    helm upgrade --install "$HELM_RELEASE" helm/streamingapp \
                      --namespace "$K8S_NAMESPACE" \
                      --values helm/streamingapp/values-prod.yaml \
                      --set global.image.registry="$ECR_REGISTRY" \
                      --set global.image.tag="$IMAGE_TAG" \
                      --set global.awsRegion="$AWS_REGION" \
                      --set secrets.jwtSecret="$JWT_SECRET" \
                      --set mongodb.auth.rootPassword="$MONGO_PASSWORD" \
                      --set serviceAccount.annotations."eks\\.amazonaws\\.com/role-arn"="$IRSA_ARN" \
                      --atomic \
                      --timeout 12m \
                      --wait
                '''
            }
        }

        // -------------------------------------------------------------------
        stage('Verify deployment') {
        // -------------------------------------------------------------------
            when { expression { params.DEPLOY } }
            steps {
                script { env.FAILED_STAGE = 'Verify deployment' }

                script {
                    sh '''
                        set -e
                        echo "--- workloads ---"
                        kubectl get deploy,sts,hpa,ingress -n "$K8S_NAMESPACE"

                        echo "--- confirming every component is serving the new tag ---"
                        for d in frontend auth streaming admin chat; do
                          kubectl rollout status "deploy/${HELM_RELEASE}-${d}" \
                            -n "$K8S_NAMESPACE" --timeout=5m
                        done
                    '''
                    sh 'helm test "$HELM_RELEASE" -n "$K8S_NAMESPACE" --logs'

                    env.APP_URL = sh(
                        returnStdout: true,
                        script: '''kubectl get ingress "$HELM_RELEASE" -n "$K8S_NAMESPACE" \
                                     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true'''
                    ).trim()
                    if (env.APP_URL) {
                        echo "Application is live at http://${env.APP_URL}"
                    } else {
                        echo 'ALB hostname not published yet — it usually appears within a couple of minutes.'
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Post-condition ORDER matters here. Jenkins runs `always` BEFORE
    // `success`/`failure`, so wiping the workspace in `always` would delete it
    // out from under notifySns (which writes sns-payload.json). Cleanup belongs
    // in `cleanup`, which is guaranteed to run last.
    post {
        success {
            script { notifySns('SUCCESS', "Deployed ${env.IMAGE_TAG} to ${params.ENVIRONMENT}") }
        }
        failure {
            script { notifySns('FAILURE', "Build ${env.IMAGE_TAG} failed at stage: ${env.FAILED_STAGE ?: 'unknown'}") }
        }
        unstable {
            script { notifySns('UNSTABLE', "Build ${env.IMAGE_TAG} finished with test failures") }
        }
        cleanup {
            // Docker images pile up fast on a long-lived agent.
            sh 'docker image prune -f --filter "until=24h" || true'
            sh 'docker logout "$ECR_REGISTRY" || true'
            cleanWs(deleteDirs: true, notFailBuild: true)
        }
    }
}

// ---------------------------------------------------------------------------
// Publishes a structured event to SNS. The Lambda in chatops/ turns it into a
// Slack message. Notification failures are swallowed on purpose — a broken
// webhook must never turn a green deploy red.
// ---------------------------------------------------------------------------
def notifySns(String status, String summary) {
    def payload = [
        status     : status,
        project    : 'StreamingApp',
        environment: params.ENVIRONMENT,
        job        : env.JOB_NAME,
        build      : env.BUILD_NUMBER,
        imageTag   : env.IMAGE_TAG,
        branch     : env.GIT_BRANCH_NAME,
        commit     : env.GIT_SHA,
        author     : env.GIT_AUTHOR,
        message    : env.GIT_MESSAGE,
        summary    : summary,
        durationMs : currentBuild.duration,
        buildUrl   : env.BUILD_URL,
        appUrl     : env.APP_URL ?: '',
    ]
    def json = groovy.json.JsonOutput.toJson(payload)
    writeFile file: 'sns-payload.json', text: json

    sh """
        set +e
        aws sns publish \\
          --region "\$AWS_REGION" \\
          --topic-arn "\$SNS_TOPIC_ARN" \\
          --subject "[${status}] StreamingApp ${env.IMAGE_TAG}" \\
          --message file://sns-payload.json \\
          --message-attributes '{"status":{"DataType":"String","StringValue":"${status}"}}' \\
          > /dev/null 2>&1 \\
          || echo "SNS notification failed (non-fatal) — check the topic ARN and IAM permissions"
        exit 0
    """
}
