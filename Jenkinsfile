pipeline {
    agent { node { label 'aws-ec2' } }

    environment {
        APP_NAME = 'weather-app'
        DOCKER_HUB_USER = 'nehoraymenashe'
        IS_OPS = 'false'
    }

    stages {
        stage('Lint') { steps { sh 'pylint *.py --fail-under=5' } }

        stage('Build') {
            steps {
                sh 'docker logout || true'
                sh "docker build --no-cache -t ${APP_NAME}:${BUILD_NUMBER} ."
                sh "docker tag ${APP_NAME}:${BUILD_NUMBER} ${DOCKER_HUB_USER}/${APP_NAME}:${BUILD_NUMBER}"
                sh "docker tag ${APP_NAME}:${BUILD_NUMBER} ${DOCKER_HUB_USER}/${APP_NAME}:latest"
            }
        }

        stage('Test') {
            steps {
                script {
                    try {
                        sh 'docker compose -f docker-compose.test.yml up -d && sleep 5'
                        sh 'curl --fail http://localhost:9090'
                    } catch (e) {
                        sh 'docker compose -f docker-compose.test.yml logs'
                        throw e
                    } finally {
                        sh 'docker compose -f docker-compose.test.yml down -v'
                    }
                }
            }
        }

        stage('Push') {
            steps {
                script { env.IS_OPS = 'true' }
                withCredentials([usernamePassword(credentialsId: 'docker-hub-credentials', usernameVariable: 'USER', passwordVariable: 'PASS')]) {
                    sh '''
                        echo $PASS | docker login -u $USER --password-stdin
                        docker push ${DOCKER_HUB_USER}/${APP_NAME}:${BUILD_NUMBER}
                        docker push ${DOCKER_HUB_USER}/${APP_NAME}:latest
                        docker logout
                    '''
                }
            }
        }
    }

    post {
        success {
            withCredentials([string(credentialsId: 'slack-webhook-success', variable: 'URL')]) {
                sh 'curl -X POST -H "Content-type: application/json" --data "{\"text\":\"✅ Build #${BUILD_NUMBER} Succeeded!\"}" $URL'
            }
        }
        failure {
            script {
                def targetHook = (env.IS_OPS == 'true') ? 'slack-webhook-failure' : 'slack-webhook-dev-failure'
                def msg = (env.IS_OPS == 'true') ? "🚨 Ops Alert: Push failed (#${BUILD_NUMBER})" : "⚠️ Dev Alert: Build/Test failed (#${BUILD_NUMBER})"
                withCredentials([string(credentialsId: targetHook, variable: 'URL')]) {
                    sh "curl -X POST -H 'Content-type: application/json' --data '{\"text\":\"${msg}\"}' \$URL"
                }
            }
        }
    }
}