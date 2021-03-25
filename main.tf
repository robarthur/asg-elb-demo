locals {
  subnet_cidr_blocks = [for cidr_block in cidrsubnets("${var.cidr_base}/16", 4,4) : cidrsubnets(cidr_block, 4, 4, 4 ,4)]
}

#
# Data
#
data "aws_ami" "amazon_linux" {
  most_recent = true

  owners = ["amazon"]
  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-ebs"]
  }
}


#
# VPC
#
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "testing-alb-cognito-auth"
  cidr = "${var.cidr_base}/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c", "${var.aws_region}d"]
  public_subnets = local.subnet_cidr_blocks[0]
  #private_subnets = local.subnet_cidr_blocks[1]

  #enable_nat_gateway = true
  #single_nat_gateway = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform = "true"
    Environment = "dev"
  }
}

#
# Security Groups
#
resource "aws_security_group" "allow_http_from_public_subnet" {
  name        = "allow_http_from_public_subnet"
  description = "Allow HTTP traffic from all public subnets"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP from public Subnets"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = module.vpc.public_subnets_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "allow_http_https_from_world" {
  name        = "allow_http_https_from_world"
  description = "Allow HTTP(s) Traffic from the world"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP from public Subnets"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from public Subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "allow_ssh_from_world" {
  name        = "allow_ssh_from_world"
  description = "Allow SSH Traffic from the world"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "SSH from world"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


#
#Launch configuration and autoscaling group
#
module "asg" {
  source = "terraform-aws-modules/autoscaling/aws"

  name = "asg-elb-demo"

  # Launch configuration
  lc_name = "asg-elb-demo-lc"

  image_id        = data.aws_ami.amazon_linux.id
  instance_type   = "t2.micro"
  security_groups = [aws_security_group.allow_http_from_public_subnet.id, aws_security_group.allow_ssh_from_world.id]

  key_name = "rob-lk"

  # Auto scaling group
  asg_name                  = "asg-elb-demo"
  vpc_zone_identifier       = module.vpc.public_subnets
  health_check_type         = "EC2"
  min_size                  = 0
  max_size                  = 1
  desired_capacity          = 1
  wait_for_capacity_timeout = 0

  tags = [
    {
      key                 = "Environment"
      value               = "dev"
      propagate_at_launch = true
    },
    {
      key                 = "Project"
      value               = "megasecret"
      propagate_at_launch = true
    },
  ]

  # Run commands at launch
  user_data     = <<-EOF
                  #!/bin/bash
                  sudo su
                  yum -y install httpd
                  mkdir -p /tmp/asg_demo/
                  wget https://asg-demo-20210318.s3.amazonaws.com/asg_demo.tar.gz -P /tmp/asg_demo/
                  tar -zxvf /tmp/asg_demo/asg_demo.tar.gz -C /tmp/asg_demo/
                  rm -f /tmp/asg_demo/asg_demo.tar.gz
                  mv /tmp/asg_demo/* /var/www/html/
                  systemctl enable httpd
                  systemctl start httpd
                  EOF
}

######
# ALB
######
module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  name = "my-alb"

  load_balancer_type = "application"

  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.allow_http_https_from_world.id]

  target_groups = [
    {
      name_prefix      = "pref-"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "instance"
    }
  ]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]

  tags = {
    Environment = "Test"
  }
}

# Create a new ALB Target Group attachment
resource "aws_autoscaling_attachment" "asg_attachment" {
  autoscaling_group_name = module.asg.this_autoscaling_group_name
  alb_target_group_arn   = module.alb.target_group_arns[0]
}