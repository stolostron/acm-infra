# Centralized golangci-lint Management

This directory contains scripts and configurations for centralized golangci-lint version management across multiple repositories.

## Quick Start

### Recommended: One-Command Lint (run-lint.sh)

Add this single line to your `Makefile`:

```makefile
.PHONY: lint
lint:
	@curl -sSL https://raw.githubusercontent.com/stolostron/acm-infra/main/scripts/lint/run-lint.sh | bash
```

That's it! The script will:
1. Auto-detect Go version from `go.mod` (falls back to system Go if no `go.mod`)
2. Install a compatible golangci-lint version (if needed)
3. Download the correct config file to a temp directory (if no local config exists)
4. Run `golangci-lint run`

**Zero configuration needed** - just run `make lint` and everything works automatically.

**Seamless Go version upgrades**: When you update `go.mod` from Go 1.21 to 1.25, the script automatically switches to golangci-lint v2 with the correct config. No manual migration required!

**go.mod-based detection**: The script reads the Go version from your project's `go.mod`, not the system-installed Go. This ensures consistent behavior between local development (where you may have a newer Go) and CI (which matches `go.mod`).

### Configuration Priority

1. **Local config** (`.golangci.yml` or `.golangci.yaml`) - if exists, used as-is
2. **Remote config** - downloaded to `/tmp/golangci-lint-config/` based on Go version

### Alternative: Separate Install and Run (install-golangci-lint.sh)

If you prefer to install separately:

```makefile
.PHONY: lint
lint: install-golangci-lint
	golangci-lint run

.PHONY: install-golangci-lint
install-golangci-lint:
	@curl -sfL https://raw.githubusercontent.com/stolostron/acm-infra/main/scripts/lint/install-golangci-lint.sh | bash
```

Note: This approach downloads the config to your project root (`.golangci.yml`).

### Override Version (Optional)

If you need to use a specific version:

```bash
GOLANGCI_LINT_VERSION=v1.59.1 make lint
```

---

## Files Included

| File | Description |
|------|-------------|
| `run-lint.sh` | **Recommended**: One-command lint runner (install + config + run) |
| `install-golangci-lint.sh` | Installation script with Go version detection |
| `golangci-lint-version.sh` | Version mapping documentation |
| `golangci-v1.yml` | Default config for golangci-lint v1.x |
| `golangci-v2.yml` | Default config for golangci-lint v2.x |

---

## Go Version Compatibility

The script reads the Go version from `go.mod` and selects the correct golangci-lint version accordingly (falls back to system Go version if no `go.mod` is found):

| Go Version | golangci-lint Version | Config File |
|------------|----------------------|-------------|
| Go 1.20 or earlier | v1.55.2 | `golangci-v1.yml` |
| Go 1.21, 1.22 | v1.59.1 | `golangci-v1.yml` |
| Go 1.23 | v1.62.2 | `golangci-v1.yml` |
| Go 1.24+ | v2.6.2 | `golangci-v2.yml` |
| Go 1.25+ | v2.6.2 | `golangci-v2.yml` |

**Important**: golangci-lint must be built with a Go version >= your project's Go version. Using the official pre-compiled binaries (which this script does) ensures compatibility.

---

## Upgrading Version

To upgrade golangci-lint for all repositories:

1. Edit the version mapping in `install-golangci-lint.sh`
2. Push to the shared repository
3. All projects will automatically use the new version on their next CI run

---

## v1 to v2 Migration

If you're upgrading from golangci-lint v1 to v2, the configuration format has changed significantly.

### Automatic Migration

```bash
golangci-lint migrate
```

### Key Changes

| v1 | v2 |
|----|-----|
| `linters.disable-all: true` | `linters.default: none` |
| `linters.enable-all: true` | `linters.default: all` |
| `issues.exclude-rules` | `linters.exclusions.rules` |
| `issues.exclude-generated` | `linters.exclusions.generated` |
| gofmt, goimports as linters | Moved to `formatters` section |
| gosimple, stylecheck | Merged into `staticcheck` |
| exportloopref | Replaced by `copyloopvar` |

For detailed migration guide, see: https://golangci-lint.run/docs/product/migration-guide/

---

## Community Best Practices

### Why Centralized Version Management?

As teams grow, ensuring everyone runs the same version of golangci-lint becomes challenging. Version inconsistency causes:
- Different linting results locally vs CI
- "Works on my machine" syndrome
- Difficulty reproducing CI failures

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GOLANGCI_CONFIG_DIR` | `/tmp/golangci-lint-config` | Config cache directory |
| `GOLANGCI_UPDATE_CONFIG` | `false` | Force re-download config if set to `true` |
| `GOLANGCI_LINT_VERSION` | (auto) | Override auto-detected golangci-lint version |

### Alternative Approaches

| Approach | Pros | Cons | Best For |
|----------|------|------|----------|
| **Shared repo + curl script** (this approach) | Unified management, works across Go versions | Network dependency | Multi-repo teams |
| **Go 1.24+ tool directive** | Native Go support, version in go.mod | Requires Go 1.24+, dependency conflicts | Single project |
| **GitHub Actions Reusable Workflows** | CI-level consistency | Local dev needs separate handling | CI-only |
| **Docker image** | Complete isolation | Local dev inconvenience | CI environments |

### Go 1.24+ Tool Directive (Alternative)

If all your projects use Go 1.24+, you can use the native tool directive:

```bash
# Add golangci-lint as a tool dependency
go get -tool github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.6.2

# Run using go tool
go tool golangci-lint run
```

However, for multi-repo teams with varying Go versions, the shared script approach is more flexible.

---

## Known Issues and Solutions

### 1. Go Version Mismatch Error

**Error**: `the Go language version (go1.22) used to build golangci-lint is lower than the targeted Go version (1.23.1)`

**Solution**: This script automatically selects a compatible version. If you see this error, update the version mapping or use the environment variable override.

### 2. Configuration Version Error

**Error**: `unsupported version of the configuration`

**Solution**: You're using a v1 config with golangci-lint v2 (or vice versa). Run `golangci-lint migrate` to convert your config, or use the correct config file for your version.

### 3. Network Issues

**Problem**: Download fails in CI or behind firewall.

**Solution**: The script skips download if the correct version is already installed. Consider caching the binary or using an internal artifact server.

---

## References

### Official Documentation
- [golangci-lint FAQ](https://golangci-lint.run/docs/welcome/faq/)
- [golangci-lint Configuration](https://golangci-lint.run/docs/configuration/)
- [Migration Guide v1→v2](https://golangci-lint.run/docs/product/migration-guide/)
- [Local Installation](https://golangci-lint.run/docs/welcome/install/local/)

### Community Discussions
- [Issue #3912: Specify version in config](https://github.com/golangci/golangci-lint/issues/3912) - Community request for version management in config
- [Discussion #3954: Sharing Configs Across Repos](https://github.com/golangci/golangci-lint/discussions/3954) - Discussion on sharing configurations
- [Issue #5032: Go version compatibility](https://github.com/golangci/golangci-lint/issues/5032) - Go version mismatch issues

### Go 1.24 Tool Management
- [Go 1.24 Tool Directive](https://medium.com/@yuseferi/managing-tool-dependencies-in-go-1-24-a-deep-dive-feb2c9e07fe9)
- [Go 1.24 Release Notes](https://go.dev/doc/go1.24)

### Best Practices Articles
- [Welcome to golangci-lint v2](https://ldez.github.io/blog/2025/03/23/golangci-lint-v2/) - v2 announcement and changes
- [Migrating to GolangCI-Lint v2](https://www.khajaomer.com/blog/level-up-your-go-linting) - Migration guide
- [Golden config for golangci-lint](https://gist.github.com/maratori/47a4d00457a92aa426dbd48a18776322) - Community recommended config

---

## License

Copyright (c) Red Hat, Inc.
Copyright Contributors to the Open Cluster Management project
