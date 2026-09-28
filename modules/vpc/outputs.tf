output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "gitlab_sg_id" {
  value = aws_security_group.gitlab.id
}

output "jenkins_sg_id" {
  value = aws_security_group.jenkins.id
}

output "certificate_arn" {
  value = aws_acm_certificate_validation.main.certificate_arn
}

output "zone_id" {
  value = data.aws_route53_zone.main.zone_id
}
