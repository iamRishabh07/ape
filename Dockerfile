FROM debian:bookworm-slim

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl unzip ca-certificates python3 python3-pip \
  && rm -rf /var/lib/apt/lists/*

# Install Terraform 1.7.5
RUN curl -fsSL https://releases.hashicorp.com/terraform/1.7.5/terraform_1.7.5_linux_amd64.zip \
    -o /tmp/terraform.zip \
  && unzip /tmp/terraform.zip -d /usr/local/bin/ \
  && rm /tmp/terraform.zip \
  && terraform version

# Install AWS CLI v2
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
  && unzip /tmp/awscliv2.zip -d /tmp \
  && /tmp/aws/install \
  && rm -rf /tmp/awscliv2.zip /tmp/aws

# Install Python dependencies for tests
RUN pip3 install --no-cache-dir --break-system-packages \
    boto3 \
    pytest \
    pytest-json-report

# Pre-download the Terraform AWS provider to avoid network calls at test time
ENV TF_PLUGIN_CACHE_DIR=/root/.terraform/plugin-cache
RUN mkdir -p $TF_PLUGIN_CACHE_DIR \
  && mkdir -p /tmp/tf-provider-init \
  && printf 'terraform {\n  required_providers {\n    aws = {\n      source  = "hashicorp/aws"\n      version = ">= 5.34, < 6.0"\n    }\n  }\n}\n' > /tmp/tf-provider-init/main.tf \
  && cd /tmp/tf-provider-init \
  && terraform init -no-color \
  && rm -rf /tmp/tf-provider-init

# AWS credentials for LocalStack
ENV AWS_ACCESS_KEY_ID=test
ENV AWS_SECRET_ACCESS_KEY=test
ENV AWS_DEFAULT_REGION=us-east-1
ENV AWS_ENDPOINT_URL=http://localhost:4566

# LOCALSTACK_AUTH_TOKEN must be passed at runtime via:
#   docker run -e LOCALSTACK_AUTH_TOKEN=<token> ...
# Do NOT hardcode the token here.

# Initialize git repo at /app so patches can be applied cleanly
RUN mkdir -p /app \
  && cd /app \
  && git init \
  && git config user.email "test@test.com" \
  && git config user.name "test"

WORKDIR /app
