variable "project" { type = string }
variable "domain_name" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "private_subnet_ids" { type = list(string) }
variable "alb_sg_id" { type = string }
variable "gitlab_sg_id" { type = string }
variable "jenkins_sg_id" { type = string }
variable "certificate_arn" { type = string }
variable "zone_id" { type = string }
variable "gitlab_ami_id" { type = string }
variable "jenkins_ami_id" { type = string }

variable "cluster_version" {
  type    = string
  default = "1.36"
}
variable "region" {
  type = string
}

variable "enable_public_endpoint" {
  type        = bool
  default     = false
  description = "Escape hatch. true exposes the API server publicly."
}



variable "admin_cidrs" {
  type        = list(string)
  description = "Addresses allowed to reach GitLab, Jenkins, staging and dev"
}

variable "environments" {
  type = map(object({
    subdomain = string
  }))

  default = {
    prod    = { subdomain = "weather" }
    staging = { subdomain = "staging" }
    dev     = { subdomain = "dev" }
  }
}
