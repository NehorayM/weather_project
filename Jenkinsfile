pipeline {
    agent { node { label 'aws-ec2' } }

    environment {
        APP_NAME = 'weather-app'
        DOCKER_HUB_USER = 'nehoraymenashe'
        IS_OPS = 'false'
    }

    stages {
        stage('code test') {
        steps {
        sh 'pylint *.py --fail-under=5'
         }
         }

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

    stage('Deploy') {
            steps {
                script { env.IS_OPS = 'true' }
                withCredentials([sshUserPrivateKey(credentialsId: 'target-ec2-ssh', keyFileVariable: 'SSH_KEY')]) {
                    sh '''
                        ssh -o StrictHostKeyChecking=no -i $SSH_KEY ubuntu@172.31.34.187"
                            if docker ps | grep -q weather-app-8001; then
                                NEW_PORT=8002
                                OLD_PORT=8001
                                NEW_NAME='weather-app-8002'
                                OLD_NAME='weather-app-8001'
                            else
                                NEW_PORT=8001
                                OLD_PORT=8002
                                NEW_NAME='weather-app-8001'
                                OLD_NAME='weather-app-8002'
                            fi

                            echo \"Deploying new version to port \$NEW_PORT...\"

                            docker pull ${DOCKER_HUB_USER}/${APP_NAME}:${BUILD_NUMBER}
                            docker run -d --name \$NEW_NAME -p \$NEW_PORT:8000 ${DOCKER_HUB_USER}/${APP_NAME}:${BUILD_NUMBER}

                            sleep 3
                            if ! curl --fail http://127.0.0.1:\$NEW_PORT; then
                                echo \"New container failed healthcheck! Aborting deploy.\"
                                docker stop \$NEW_NAME && docker rm \$NEW_NAME
                                exit 1
                            fi

                            sudo sed -i \"s/http:\/\/127.0.0.1:\$OLD_PORT/http:\/\/127.0.0.1:\$NEW_PORT/g\" /etc/nginx/sites-available/default
                            sudo nginx -s reload

                            echo \"Stopping old container \$OLD_NAME...\"
                            docker stop \$OLD_NAME || true
                            docker rm \$OLD_NAME || true
                        "
                    '''
                }
            }
        }
    }

    post {
        success {
            withCredentials([string(credentialsId: 'slack-webhook-success', variable: 'URL')]) {
                sh "curl -X POST -H 'Content-type: application/json' --data '{\"text\":\"Build #${BUILD_NUMBER} Succeeded!\"}' \$URL"
            }
        }
        failure {
            script {
                def targetHook = (env.IS_OPS == 'true') ? 'slack-webhook-failure' : 'slack-webhook-dev-failure'
                def msg = (env.IS_OPS == 'true') ? "Ops Alert: Push failed (#${BUILD_NUMBER})" : "Dev Alert: Build/Test failed (#${BUILD_NUMBER})"
                withCredentials([string(credentialsId: targetHook, variable: 'URL')]) {
                    sh "curl -X POST -H 'Content-type: application/json' --data '{\"text\":\"${msg}\"}' \$URL"
                }
            }
        }
    }
}