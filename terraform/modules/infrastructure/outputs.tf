output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "jenkins_instance_id" {
  value = aws_instance.jenkins.id
}

output "gitlab_instance_id" {
  value = aws_instance.gitlab.id
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_ca" {
  value = module.eks.cluster_certificate_authority_data
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "gitlab_private_ip" {
  value = aws_instance.gitlab.private_ip
}

output "jenkins_private_ip" {
  value = aws_instance.jenkins.private_ip
}
