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

## Contributing

**Important**: This repository uses GitHub Actions workflows that require access to repository secrets for CI/CD operations. Due to GitHub's security model, secrets are not available to workflows triggered by pull requests from forked repositories.

Therefore, **please do not submit pull requests from forks**. Instead:

1. Request write access to this repository
2. Create a feature branch directly in this repository
3. Submit your pull request from that branch

This ensures all CI checks can run properly with the required credentials.
