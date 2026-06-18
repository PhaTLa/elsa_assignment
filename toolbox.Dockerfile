# Toolbox Container for DevOps Assignment
# Includes: kubectl, helm, k6, terraform, git, jq, curl
# Base: Alpine 3.19

FROM alpine:3.19

LABEL maintainer="DevOps Team"
LABEL description="DevOps Toolbox - kubectl, helm, k6, terraform, git"

# Install essential packages
RUN apk update && apk add --no-cache \
    bash \
    curl \
    wget \
    openssl \
    ca-certificates \
    jq \
    yq \
    vim \
    git \
    python3 \
    py3-pip

# Install kubectl
RUN curl -L "https://dl.k8s.io/release/stable.txt" -o /tmp/kubectl_version && \
    KUBECTL_VERSION=$(cat /tmp/kubectl_version) && \
    curl -L "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

# Install helm 3.14
RUN curl -L "https://get.helm.sh/helm-v3.14.0-linux-amd64.tar.gz" | tar xz -C /tmp && \
    mv /tmp/linux-amd64/helm /usr/local/bin/ && \
    chmod +x /usr/local/bin/helm

# Install k6 (download directly)
RUN K6_VERSION=v0.52.0 && \
    curl -L "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-amd64.tar.gz" | tar xz -C /tmp && \
    cp /tmp/k6-${K6_VERSION}-linux-amd64/k6 /usr/local/bin/ && \
    chmod +x /usr/local/bin/k6

# Install terraform
RUN curl -L "https://releases.hashicorp.com/terraform/1.8.0/terraform_1.8.0_linux_amd64.zip" -o /tmp/terraform.zip && \
    unzip /tmp/terraform.zip -d /usr/local/bin && \
    chmod +x /usr/local/bin/terraform && \
    rm /tmp/terraform.zip

# Note: Trivy & Semgrep are optional - can be installed manually in /scripts if needed for Part 4

# Create directories
RUN mkdir -p /scripts /helm /k6 /terraform /grafana /troubleshoot /tmp/k6-results

# Set working directory
WORKDIR /scripts

# Default entrypoint
ENTRYPOINT ["/bin/bash"]
