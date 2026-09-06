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
      resources:
        requests: {cpu: "100m", memory: "256Mi"}
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
        requests: {cpu: "500m", memory: "1Gi", ephemeral-storage: "4Gi"}
        limits: {cpu: "1500m", memory: "2Gi", ephemeral-storage: "10Gi"}
      volumeMounts:
        - name: layers
          mountPath: /home/build/.local/share/containers
        - name: shared
          mountPath: /shared
    - name: tools
      image: alpine/k8s:1.31.0
      command: ["sleep", "infinity"]
      resources:
        requests: {cpu: "100m", memory: "256Mi"}
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

  environment {
    ECR_REPO   = '225317159123.dkr.ecr.eu-north-1.amazonaws.com/weather'
    AWS_REGION = 'eu-north-1'
    CHART_REPO = '10.0.3.92:8000/whetherappgroup/weather-app-chart.git'
  }

  options {
    timeout(time: 20, unit: 'MINUTES')
    disableConcurrentBuilds()
  }

  stages {

    stage('Version') {
      steps {
        script {
          if (env.BRANCH_NAME == 'main' || env.BRANCH_NAME.startsWith('hotfix/')) {
            env.VALUES_FILE = 'values-prod.yaml'
          } else if (env.BRANCH_NAME.startsWith('release/')) {
            env.VALUES_FILE = 'values-staging.yaml'
          } else if (env.BRANCH_NAME == 'develop') {
            env.VALUES_FILE = 'values-dev.yaml'
          } else {
            env.VALUES_FILE = ''
          }

          env.TAG = "${readFile('VERSION').trim()}-${env.BUILD_NUMBER}"
          currentBuild.displayName = "${env.BRANCH_NAME} ${env.TAG} -> ${env.VALUES_FILE ?: 'no deploy'}"
        }
      }
    }

    stage('Lint') {
      steps {
        container('python') {
          sh 'pip install --quiet pylint && pylint *.py --fail-under=5'
        }
      }
    }

    stage('Build') {
      steps {
        container('tools') {
          sh 'aws ecr get-login-password --region eu-north-1 > /shared/ecr.token'
        }
        container('buildah') {
          sh '''
            set -e
            CTR=$(buildah from ${ECR_REPO}:${TAG})
            buildah run $CTR python app.py &
            APP_PID=$!
            sleep 6

            echo "Executing Health Check via curl"
            if curl -s -f http://127.0.0.1:5000/ > /dev/null; then
              echo " Health Check PASSED: Container is responding with 200 OK"
            else
              echo " Health Check FAILED: Container did not respond as expected"
              kill -9 $APP_PID 2>/dev/null || true
              buildah rm $CTR 2>/dev/null || true
              exit 1
            fi

            echo "cleanup..."
            kill -9 $APP_PID 2>/dev/null || true
            buildah rm $CTR 2>/dev/null || true
          '''
        }
      }
    }

    stage('Push') {
      when { expression { env.VALUES_FILE != '' } }
      steps {
        container('buildah') {
          sh 'buildah push ${ECR_REPO}:${TAG}'
        }
      }
    }

    stage('Update chart') {
      when { expression { env.VALUES_FILE != '' } }
      steps {
        container('tools') {
          withCredentials([usernamePassword(
            credentialsId: 'gitlab-chart-repo',
            usernameVariable: 'GIT_USER',
            passwordVariable: 'GIT_TOKEN')]) {
            sh '''
              set -e
              rm -rf chart-repo
              git clone http://${GIT_USER}:${GIT_TOKEN}@${CHART_REPO} chart-repo
              cd chart-repo
              yq -i ".image.tag = \\"${TAG}\\"" ${VALUES_FILE}
              git config user.email "jenkins@nehorai-menashe.click"
              git config user.name "jenkins"
              git add ${VALUES_FILE}
              if git diff --cached --quiet; then
                echo "no change to ${VALUES_FILE}, nothing to commit"
                exit 0
              fi
              git commit -m "${VALUES_FILE}: ${TAG}"
              git push origin main
            '''
          }
        }
      }
    }
  }

  post {
    success {
      withCredentials([string(credentialsId: 'slack-webhook-success', variable: 'URL')]) {
        sh 'curl -sS -X POST -H "Content-type: application/json" --data "{\\"text\\":\\"${BRANCH_NAME} ${TAG} -> ${VALUES_FILE ?: \'build only\'} succeeded\\"}" $URL'
      }
    }
    failure {
      script {
        def isOps = (env.VALUES_FILE == 'values-prod.yaml' || env.VALUES_FILE == 'values-staging.yaml')
        def hook  = isOps ? 'slack-webhook-failure' : 'slack-webhook-dev-failure'
        def msg   = isOps ? "Ops alert: ${BRANCH_NAME} ${TAG} failed" : "Dev alert: ${BRANCH_NAME} ${TAG} failed"
        withCredentials([string(credentialsId: hook, variable: 'URL')]) {
          sh "curl -sS -X POST -H 'Content-type: application/json' --data '{\"text\":\"${msg}\"}' \$URL"
        }
      }
    }
  }
}