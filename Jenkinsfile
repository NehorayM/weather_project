pipeline {
    agent {
        node {
            label 'aws-ec2' // ה-Label שהגדרת בתבנית ה-AMI למטה
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
                echo 'Running Pylint in isolated Python container...'
                sh '''
                    docker run --rm -v $WORKSPACE:/app -w /app python:3.11-slim sh -c "
                        pip install --quiet pylint
                        SCORE=\$(pylint main.py --exit-zero | grep -oP 'rated at \\K[0-9.]+' || echo '0')
                        echo \"Pylint score: \$SCORE\"

                        python3 -c \"import sys; sys.exit(0 if float('\$SCORE') >= 5.0 else 1)\"
                    "
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