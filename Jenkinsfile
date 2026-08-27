pipeline {
  agent {
    kubernetes {
      cloud 'eks'
      namespace 'jenkins'
      defaultContainer 'tools'
      yaml """
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins-agent
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  containers:
    - name: python
      image: python:3.11-slim
      command: ["sleep", "infinity"]
      env:
        - name: HOME
          value: /tmp
      resources:
        requests: {cpu: "50m", memory: "128Mi"}
        limits: {cpu: "500m", memory: "512Mi"}
    - name: buildah
      image: quay.io/buildah/stable:v1.40
      command: ["sleep", "infinity"]
      env:
        - name: BUILDAH_ISOLATION
          value: chroot
        - name: STORAGE_DRIVER
          value: vfs
      securityContext:
        allowPrivilegeEscalation: true
        capabilities:
          add: ["SETUID", "SETGID"]
      resources:
        requests: {cpu: "100m", memory: "256Mi", ephemeral-storage: "2Gi"}
        limits: {cpu: "1500m", memory: "3Gi", ephemeral-storage: "10Gi"}
      volumeMounts:
        - name: layers
          mountPath: /home/build/.local/share/containers
        - name: shared
          mountPath: /shared
    - name: tools
      image: alpine/k8s:1.31.0
      command: ["sleep", "infinity"]
      resources:
        requests: {cpu: "50m", memory: "128Mi"}
        limits: {cpu: "500m", memory: "512Mi"}
      volumeMounts:
        - name: shared
          mountPath: /shared
  volumes:
    - name: layers
      emptyDir: { sizeLimit: 15Gi }
    - name: shared
      emptyDir: {}
"""
    }
  }

  parameters {
    string(name: 'ROLLBACK_TAG', defaultValue: '', description: 'e.g. 1.1.0-15 (empty = normal build)')
  }

  environment {
    ECR_REPO   = '225317159123.dkr.ecr.eu-north-1.amazonaws.com/weather'
    APP_BRANCH = 'main'
    TAG        = ''
    TARGET_NS  = ''
  }

  options {
    timeout(time: 20, unit: 'MINUTES')
    disableConcurrentBuilds()
  }

  stages {
    stage('Version') {
      steps {
        script {
          String branch = env.gitlabBranch ?: env.gitlabSourceBranch ?: env.GIT_BRANCH ?: env.BRANCH_NAME ?: 'main'
          branch = branch.replaceAll('^refs/heads/', '').replaceAll('^origin/', '').replaceAll('^\\*/', '').trim()
          if (!branch) { branch = 'main' }

          env.APP_BRANCH = branch

          if (params.ROLLBACK_TAG?.trim()) {
            env.TAG = params.ROLLBACK_TAG.trim()
          } else {
            String safeBranch = branch.replaceAll('/', '-')
            env.TAG = "${safeBranch}-${env.BUILD_NUMBER}"
          }

          if (branch == 'main' || branch == 'master') {
            env.TARGET_NS = 'weather-prod'
          } else if (branch.startsWith('release/')) {
            env.TARGET_NS = 'weather-staging'
          } else {
            env.TARGET_NS = 'weather-dev'
          }

          echo "Branch: ${env.APP_BRANCH} | Tag: ${env.TAG} | Namespace: ${env.TARGET_NS}"
        }
      }
    }

    stage('Lint') {
      when { expression { !params.ROLLBACK_TAG } }
      steps {
        container('python') {
          sh '''
            export HOME=/tmp
            export PATH=$PATH:/tmp/.local/bin
            pip install --quiet --no-cache-dir pylint
            pylint *.py --fail-under=5
          '''
        }
      }
    }

    stage('Build') {
      when { expression { !params.ROLLBACK_TAG } }
      steps {
        container('tools') {
          sh 'aws ecr get-login-password --region eu-north-1 > /shared/ecr.token'
        }
        container('buildah') {
          sh '''
            buildah login -u AWS --password-stdin ${ECR_REPO%%/*} < /shared/ecr.token
            buildah bud --build-arg APP_VERSION=${TAG} -t ${ECR_REPO}:${TAG} .
          '''
        }
      }
    }

    stage('Push') {
      when {
        allOf {
          expression { !params.ROLLBACK_TAG }
          expression { env.TARGET_NS != '' }
        }
      }
      steps {
        container('buildah') {
          sh 'buildah push ${ECR_REPO}:${TAG}'
        }
      }
    }

    stage('Deploy') {
      when { expression { env.TARGET_NS != '' } }
      steps {
        container('tools') {
          sh '''
            kubectl -n ${TARGET_NS} set image deployment/weather-app weather-app=${ECR_REPO}:${TAG}
            kubectl -n ${TARGET_NS} rollout status deployment/weather-app --timeout=300s
          '''
        }
      }
    }
  }

  post {
    success {
      withCredentials([string(credentialsId: 'slack-webhook-success', variable: 'URL')]) {
        sh 'curl -sS -X POST -H "Content-type: application/json" --data "{\\"text\\":\\"${APP_BRANCH} ${TAG} -> ${TARGET_NS} succeeded\\"}" $URL'
      }
    }
    failure {
      script {
        def isOps = (env.TARGET_NS == 'weather-prod' || env.TARGET_NS == 'weather-staging')
        def hook  = isOps ? 'slack-webhook-failure' : 'slack-webhook-dev-failure'
        def bName = env.APP_BRANCH ?: 'unknown'
        def tName = env.TAG ?: 'untagged'
        def msg   = "${isOps ? 'Ops alert' : 'Dev alert'}: ${bName} ${tName} failed"
        withCredentials([string(credentialsId: hook, variable: 'URL')]) {
          sh "curl -sS -X POST -H 'Content-type: application/json' --data '{\"text\":\"${msg}\"}' \$URL"
        }
      }
    }
  }
}
