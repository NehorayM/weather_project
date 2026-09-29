# weather app on EKS

a flask weather app that runs on EKS in eu-north-1 with a full CI/CD and GitOps flow

## folders

terraform is the infrastructure code for the VPC and the EC2 servers and the ALBs and the EKS cluster

wetherApp is the flask app with the Dockerfile and the Jenkinsfile

weather-app-chart is the helm chart and the argocd applications

scripts has what i run every day. apply in the morning and status any time and destroy in the evening. scripts/README.md says when to use each one

## how it works

jenkins builds the image with buildah and pushes it to ECR

then it writes the new image tag into the chart repo

argocd sees the commit and syncs dev and staging by itself and prod by a manual sync

## note

in real life these are three separate repos in gitlab

this repo is a copy of all three so the whole project is in one place

secrets and terraform state are not in this repo
