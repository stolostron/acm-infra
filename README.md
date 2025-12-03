# ACM Infrastructure

Infrastructure tools and configurations for Red Hat Advanced Cluster Management (ACM).

## Contents

- **acm-config/** - ACM configuration files (submodule from [stolostron/acm-config](https://github.com/stolostron/acm-config))
- **konflux/** - Konflux CI/CD integration tools
  - **konflux-jira-integration/** - Automated Konflux build compliance scanner with JIRA integration

## Getting Started

Clone the repository with submodules:

```bash
git clone --recurse-submodules https://github.com/stolostron/acm-infra.git
```

Or update submodules after cloning:

```bash
git submodule update --init --recursive
```
