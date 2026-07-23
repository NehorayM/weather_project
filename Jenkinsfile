pipeline {
    agent {
        node {
            label 'aws-ec2'
        }
    }

    environment {
        APP_NAME = 'weather-app'
    }

    stages {
        stage('Init') {
            steps {
                echo "Building application: ${env.APP_NAME}"
            }
        }

        stage('Code Check (Linting)') {
        steps {
            sh  '''
            pylint *.py --fail-under=5
        '''
        }
        }

        stage('Build Docker Image') {
            steps {
                echo 'Building Docker Image...'
                sh "docker build -t ${APP_NAME}:${BUILD_NUMBER} ."
            }
        }

        stage('Test Image') {
            steps {
                script {
                    try {
                        echo 'Starting containers via Docker Compose...'
                        sh 'docker compose -f docker-compose.test.yml up -d'
                        sh 'sleep 3'
                        sh 'curl --fail http://localhost:8081'
                    } finally {
                        sh 'docker compose -f docker-compose.test.yml down -v'
                    }
                }
            }
        }
    }
}