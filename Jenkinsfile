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


        stage('Test Image') {
        steps {
            script {
                try {
                    echo 'Starting containers via Docker Compose...'
                    sh 'docker compose up -d'

                    sh 'sleep 5'

                    sh 'curl --fail http://localhost:9090'
                } finally {
                    sh 'docker compose down -v'
                }
            }
        }
        }

        stage('Build Docker Image') {
            steps {
                echo 'Building Docker Image...'
                sh "docker build -t ${APP_NAME}:${BUILD_NUMBER} ."
            }
        }

    }
}