

output "cluster_endpoint" {
  value       = module.infrastructure.cluster_endpoint
  description = "API server URL. Strip https:// for the /etc/hosts entry."
}

output "jenkins_instance_id" {
  value       = module.infrastructure.jenkins_instance_id
  description = "Tunnel target — the box with VPC-internal access to the API."
}


output "cluster_name" {
  value = module.infrastructure.cluster_name
}

output "ecr_repository_url" {
  value       = module.infrastructure.ecr_repository_url
  description = "Registry URL for the pipeline's push step."
}

output "alb_dns_name" {
  value       = module.infrastructure.alb_dns_name
  description = "curl this directly if DNS has not propagated yet."
}

output "gitlab_instance_id" {
  value = module.infrastructure.gitlab_instance_id
}

output "certificate_arn" {
  value = module.vpc.certificate_arn
}

output "alb_security_group_id" {
  value = module.vpc.alb_sg_id
}
