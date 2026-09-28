#!/bin/bash

ENDPOINT="DD9C6733EA5E98B1C040DC783A5CAF50.yl4.eu-north-1.eks.amazonaws.com"
JENKINS_ID="i-01ff1141b95300f69"

grep -q "$ENDPOINT" /etc/hosts || echo "127.0.0.1 $ENDPOINT" | sudo tee -a /etc/hosts

aws ssm start-session \
  --target "$JENKINS_ID" \
  --region eu-north-1 \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$ENDPOINT,portNumber=443,localPortNumber=8443"
