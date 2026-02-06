#!/bin/bash

###############################################################################
# Copyright (c) Red Hat, Inc.
# Copyright Contributors to the Open Cluster Management project
###############################################################################

# Centralized golangci-lint version management
#
# The install script will AUTO-DETECT Go version and select a compatible
# golangci-lint version. This file documents the version mapping.
#
# Go version compatibility mapping:
#   Go 1.24+            -> v2.8.0
#   Go 1.23             -> v2.3.1 (last v2 supporting Go 1.23)
#   Go 1.21, 1.22       -> v1.64.8 (latest v1)
#   Go 1.20 or earlier  -> v1.55.2
#
# To override auto-detection, set GOLANGCI_LINT_VERSION environment variable:
#   GOLANGCI_LINT_VERSION=v1.59.1 make lint
#
###############################################################################

# NOTE: Do NOT set GOLANGCI_LINT_VERSION here unless you want to disable
# auto-detection. The install script will auto-detect based on Go version.
#
# Uncomment the following line ONLY if you want to force a specific version
# across all Go versions (not recommended):
#
# export GOLANGCI_LINT_VERSION="v2.8.0"
