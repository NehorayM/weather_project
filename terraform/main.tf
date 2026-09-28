

module "vpc" {
  source = "./modules/vpc"

  project     = var.project
  region      = var.region
  vpc_cidr    = var.vpc_cidr
  domain_name = var.domain_name
}


module "kubernetes" {
  source             = "./modules/kubernetes"
  weather_api_key    = var.weather_api_key
  ecr_repository_url = module.infrastructure.ecr_repository_url
  environments       = var.environments
  slack_webhook_url  = var.slack_webhook_url
}


module "infrastructure" {
  source = "./modules/infrastructure"

  project            = var.project
  domain_name        = var.domain_name
  region             = var.region
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids
  alb_sg_id          = module.vpc.alb_sg_id
  gitlab_sg_id       = module.vpc.gitlab_sg_id
  jenkins_sg_id      = module.vpc.jenkins_sg_id
  certificate_arn    = module.vpc.certificate_arn
  zone_id            = module.vpc.zone_id

  gitlab_ami_id   = var.gitlab_ami_id
  jenkins_ami_id  = var.jenkins_ami_id
  cluster_version = var.cluster_version


  admin_cidrs  = var.admin_cidrs
  environments = var.environments
}

