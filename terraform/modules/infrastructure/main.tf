

#-------IAM---------

# iam role that will let the ec2 instances hve 
# greants permissions to aws sts to generate temp security credentials
# exploicity allows ec2 service to assume rule
resource "aws_iam_role" "ec2" {
  name = "${var.project}-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2"
  role = aws_iam_role.ec2.name
}

# ---- ec2 from golden amis

resource "aws_instance" "gitlab" {
  ami                    = var.gitlab_ami_id
  instance_type          = "m7i-flex.large"
  subnet_id              = var.private_subnet_ids[0]
  vpc_security_group_ids = [var.gitlab_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  private_ip             = "10.0.3.92"

  tags = {
    Name = "${var.project}-gitlab"
  }
}

resource "aws_instance" "jenkins" {
  ami                    = var.jenkins_ami_id
  instance_type          = "m7i-flex.large"
  subnet_id              = var.private_subnet_ids[1]
  vpc_security_group_ids = [var.jenkins_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  private_ip             = "10.0.4.70"

  tags = {
    Name = "${var.project}-jenkins"
  }
}

# ecr

resource "aws_ecr_repository" "app" {
  name                 = var.project
  image_tag_mutability = "IMMUTABLE" # a tag never can point to diff bytes
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
}


/*
  Packet flow:
  1. Route 53 alias  ->  ALB public IP
  2. ALB :80         ->  301 redirect to :443
  3. ALB :443        ->  TLS terminates here, Host header becomes readable
  4. listener rules, lowest priority first:
       gitlab-privet.* + admin source IP  -> tg-gitlab   -> EC2 :8000
       jenkins.*       + admin source IP  -> tg-jenkins  -> EC2 :80
       staging.*       + admin source IP  -> tg-staging  -> node :30082
       dev.*           + admin source IP  -> tg-dev      -> node :30083
       tg-prod     -> node :30081
  5. NodePort  ->  kube-proxy  ->  a ready pod on :8000
*/

resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  tags = {
    Name = "${var.project}-alb"
  }
}
# targets group for gitlab, jenkins and eks
resource "aws_lb_target_group" "gitlab" {
  name     = "${var.project}-tg-gitlab"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/-/health"
    matcher             = "200,403"
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

}

resource "aws_lb_target_group_attachment" "gitlab" {

  target_group_arn = aws_lb_target_group.gitlab.arn
  target_id        = aws_instance.gitlab.id
  port             = 8000
}

resource "aws_lb_target_group" "jenkins" {
  name     = "${var.project}-tg-jenkins"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/login"
    matcher             = "200,403"
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "jenkins" {
  target_group_arn = aws_lb_target_group.jenkins.arn
  target_id        = aws_instance.jenkins.id
  port             = 80
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

locals {
  restricted = {
    gitlab = {
      host     = "gitlab-privet.${var.domain_name}"
      tg       = aws_lb_target_group.gitlab.arn
      priority = 100
    }
    jenkins = {
      host     = "jenkins.${var.domain_name}"
      tg       = aws_lb_target_group.jenkins.arn
      priority = 110
    }
  }
}


resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener_rule" "restricted_allow" {
  for_each = local.restricted

  listener_arn = aws_lb_listener.https.arn
  priority     = each.value.priority

  condition {
    host_header {
      values = [each.value.host]
    }
  }

  condition {
    source_ip {
      values = var.admin_cidrs
    }
  }

  action {
    type             = "forward"
    target_group_arn = each.value.tg
  }
}
resource "aws_lb_listener_rule" "restricted_deny" {
  for_each = local.restricted

  listener_arn = aws_lb_listener.https.arn
  priority     = each.value.priority + 1

  condition {
    host_header {
      values = [each.value.host]
    }
  }

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}
#----------------- DNS -----------------


resource "aws_route53_record" "gitlab" {
  zone_id = var.zone_id
  name    = "gitlab-privet.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "jenkins" {
  zone_id = var.zone_id
  name    = "jenkins.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

