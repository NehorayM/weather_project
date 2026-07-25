pipeline {
    agent {
        node {
            label 'aws-ec2'
        }
    }

    environment {
        APP_NAME = 'weather-app'
        DOCKER_HUB_USER = 'nehoraymenashe'
    }

    stages {
        stage('Init') {
            steps {
                echo "Building application: ${env.APP_NAME} (Build #${env.BUILD_NUMBER})"
            }
        }

        stage('Code Check (Linting)') {
            steps {
                echo 'Running Pylint code analysis...'
                sh 'pylint *.py --fail-under=5'
            }
        }

        stage('Build Docker Image') {
            steps {
                echo "Building Docker image: ${env.DOCKER_HUB_USER}/${env.APP_NAME}:${env.BUILD_NUMBER}"
                sh "docker build --no-cache -t ${env.APP_NAME}:${env.BUILD_NUMBER} ."
                sh "docker tag ${env.APP_NAME}:${env.BUILD_NUMBER} ${env.DOCKER_HUB_USER}/${env.APP_NAME}:${env.BUILD_NUMBER}"
                sh "docker tag ${env.APP_NAME}:${env.BUILD_NUMBER} ${env.DOCKER_HUB_USER}/${env.APP_NAME}:latest"
            }
        }

        stage('Test Image') {
            steps {
                script {
                    try {
                        echo 'Starting test environment via Docker Compose...'
                        sh 'docker compose -f docker-compose.test.yml up -d'

                        echo 'Checking running containers...'
                        sh 'docker ps -a'

                        echo 'Waiting for application to boot...'
                        sh 'sleep 5'

                        echo 'Testing endpoint reachability...'
                        sh 'curl --fail http://localhost:9090'
                    } catch (Exception e) {
                        echo '>>> TEST FAILED! Printing container logs for debugging:'
                        sh 'docker compose -f docker-compose.test.yml logs'
                        throw e
                    } finally {
                        echo 'Cleaning up test environment...'
                        sh 'docker compose -f docker-compose.test.yml down -v'
                    }
                }
            }
        }

        stage('Push to Docker Hub') {
            steps {
                echo 'Logging in and pushing image to Docker Hub...'
                withCredentials([usernamePassword(credentialsId: 'docker-hub-credentials', usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                    sh 'echo $DOCKER_PASS | docker login -u $DOCKER_USER --password-stdin'
                    sh "docker push ${env.DOCKER_HUB_USER}/${env.APP_NAME}:${env.BUILD_NUMBER}"
                    sh "docker push ${env.DOCKER_HUB_USER}/${env.APP_NAME}:latest"
                }
            }
        }
    }
}