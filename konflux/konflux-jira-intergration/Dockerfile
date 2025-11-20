# Konflux Compliance Scanner Docker Image
# This image contains all tools needed to run compliance.sh and create-compliance-jira-issues.sh

FROM registry.access.redhat.com/ubi9/ubi:latest

LABEL maintainer="ACM/MCE Team" \
      description="Konflux compliance scanner with JIRA integration" \
      version="1.0"

# Install required tools
RUN dnf install -y --allowerasing \
    # Core utilities
    bash \
    curl \
    git \
    jq \
    tar \
    # Container image tools
    skopeo \
    # Cleanup
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Install yq (YAML processor)
RUN curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# Install kubectl
RUN curl --retry 3 --retry-delay 2 -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
    && rm kubectl

# Install OpenShift CLI (oc)
RUN OC_VERSION=$(curl -s https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt | grep 'Name:' | awk '{print $2}') \
    && curl --retry 5 --retry-delay 3 --http1.1 -L https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-linux.tar.gz -o /tmp/oc.tar.gz \
    && tar -xzf /tmp/oc.tar.gz -C /usr/local/bin/ oc kubectl \
    && chmod +x /usr/local/bin/oc \
    && rm -f /tmp/oc.tar.gz

# Install jira-cli
RUN JIRA_CLI_VERSION=$(curl -s https://api.github.com/repos/ankitpokhrel/jira-cli/releases/latest | jq -r '.tag_name' | sed 's/^v//') \
    && curl --retry 3 --retry-delay 2 -LO "https://github.com/ankitpokhrel/jira-cli/releases/download/v${JIRA_CLI_VERSION}/jira_${JIRA_CLI_VERSION}_linux_x86_64.tar.gz" \
    && tar -xzf "jira_${JIRA_CLI_VERSION}_linux_x86_64.tar.gz" -C /tmp \
    && find /tmp -name jira -type f -exec mv {} /usr/local/bin/jira \; \
    && chmod +x /usr/local/bin/jira \
    && rm -rf "jira_${JIRA_CLI_VERSION}_linux_x86_64.tar.gz" /tmp/bin /tmp/completions /tmp/man

# Create working directory
WORKDIR /workspace

# Clone installer-dev-tools repo and copy required scripts
ARG REPO_URL=https://github.com/stolostron/installer-dev-tools.git
ARG REPO_BRANCH=main

RUN git clone --depth 1 --branch ${REPO_BRANCH} ${REPO_URL} /tmp/installer-dev-tools && \
    cp /tmp/installer-dev-tools/scripts/konflux/compliance.sh /workspace/compliance.sh && \
    cp /tmp/installer-dev-tools/scripts/konflux/create-compliance-jira-issues.sh /workspace/create-compliance-jira-issues.sh && \
    cp /tmp/installer-dev-tools/scripts/konflux/component-squad.yaml /workspace/component-squad.yaml && \
    chmod +x /workspace/compliance.sh /workspace/create-compliance-jira-issues.sh && \
    rm -rf /tmp/installer-dev-tools

# Copy local entrypoint script
COPY entrypoint.sh /workspace/entrypoint.sh
RUN chmod +x /workspace/entrypoint.sh

# Create data directory for output
RUN mkdir -p /workspace/data /workspace/logs

# Set environment variables with defaults
ENV SCRIPT_DIR=/workspace \
    PATH=/workspace:$PATH

# Default command runs the full compliance workflow
# This can be overridden in the CronJob
ENTRYPOINT ["/workspace/entrypoint.sh"]
