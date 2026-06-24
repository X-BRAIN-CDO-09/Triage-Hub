# Find the latest Ubuntu 22.04 LTS Jammy AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Security Group for Customer EC2 (in Customer VPC)
resource "aws_security_group" "ec2_sg" {
  name        = "ec2-spot-sg-${var.environment}"
  description = "Allow SSH, HTTP, HTTPS, K3s API, and ArgoCD inbound traffic, plus all outbound traffic"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    # SUGGEST: Không mở SSH 0.0.0.0/0 — đã có SSM Session Manager (IAM role đã attach)
    # Restrict về IP cụ thể hoặc xóa hẳn ingress port 22
    # Tham khảo: TERRAFORM_BEST_PRACTICES.md §8
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "K3s API Server"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Argo CD UI/API Port Forwarding Default"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "ec2-spot-sg-${var.environment}"
  }
}

# EC2 Instance for Customer App (deployed as Spot Instance)
resource "aws_instance" "spot_instance" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.large"
  # SUGGEST: Dùng var.instance_type thay hardcode — module không nên quyết định instance size
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  instance_market_options {
    market_type = "spot"
    spot_options {
      max_price          = null
      spot_instance_type = "one-time"
    }
  }

  # SUGGEST: Tách user_data ra file scripts/setup.sh và dùng templatefile()
  # Ví dụ: user_data = base64encode(templatefile("${path.module}/scripts/setup.sh", { ... }))
  # Lý do: 55 dòng bash inline khó maintain + không highlight syntax
  # Tham khảo: TERRAFORM_BEST_PRACTICES.md §11
  user_data = <<-EOF
              #!/bin/bash
              # Wait for internet connectivity
              sleep 10
              apt-get update -y
              apt-get install -y curl unzip

              # Install AWS CLI v2
              curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              unzip awscliv2.zip
              ./aws/install
              rm -rf awscliv2.zip aws

              # Install Argo Rollouts CLI plugin
              curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
              chmod +x ./kubectl-argo-rollouts-linux-amd64
              mv ./kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts

              # Export PATH to ensure /usr/local/bin is available
              export PATH=$PATH:/usr/local/bin

              # 1. Install K3s (BẺ KHÓA dải cổng sang 80-40000 và cấp quyền đọc config)
              export K3S_KUBECONFIG_MODE="644"
              curl -sfL https://get.k3s.io | sh -s - --disable traefik --kube-apiserver-arg="service-node-port-range=80-40000"

              # Wait for K3s/kubectl to be fully up
              export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
              until kubectl get nodes; do
                sleep 5
              done

              # Sao chép kubeconfig cho ubuntu user để gõ kubectl không cần sudo/export
              mkdir -p /home/ubuntu/.kube
              cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
              chown -R ubuntu:ubuntu /home/ubuntu/.kube

              # 2. Fix CoreDNS loops/upstream DNS forwarder (đợi configmap xuất hiện rồi mới patch)
              until kubectl get configmap coredns -n kube-system; do
                sleep 5
              done
              kubectl get configmap coredns -n kube-system -o yaml | sed 's/forward \. \/etc\/resolv\.conf/forward . 1.1.1.1 8.8.8.8/g' | kubectl apply -f -
              kubectl rollout restart deployment coredns -n kube-system

              # 3. Create Argo CD namespace and install
              kubectl create namespace argocd
              kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

              # 4. Đợi dịch vụ argocd-server được tạo xong rồi mới ÉP sang NodePort cổng 8080
              until kubectl get svc argocd-server -n argocd; do
                sleep 5
              done
              kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort", "ports": [{"name": "https", "port": 443, "nodePort": 8080}]}}'

              # 5. Cài đặt Helm tự động
              curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
              EOF

  tags = {
    Name = "t3-xlarge-spot-instance"
  }
}

# IAM Role for EC2 with SSM access
resource "aws_iam_role" "ec2_role" {
  name = "triage-customer-ec2-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "triage-customer-ec2-role-${var.environment}"
  }
}

# Attach SSM Policy for Session Manager
resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Attach ECR Read-Only Policy
resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# IAM Instance Profile for EC2
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "triage-customer-ec2-profile-${var.environment}"
  role = aws_iam_role.ec2_role.name
}
