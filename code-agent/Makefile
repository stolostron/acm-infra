# Code Agent Image Build
#
# Build a unified AI coding agent image with Gemini, Claude, and OpenCode CLIs.
#

# Image configuration
REGISTRY ?= quay.io
ORGANIZATION ?= stolostron
IMAGE_NAME ?= code-agent
IMAGE_TAG ?= latest

# Full image reference
IMAGE := $(REGISTRY)/$(ORGANIZATION)/$(IMAGE_NAME):$(IMAGE_TAG)

# Build configuration
DOCKERFILE ?= Dockerfile
PLATFORM ?= linux/amd64

.PHONY: build build-local clean help

# Default target
.DEFAULT_GOAL := help

## build: Build and push multi-arch image (amd64 + arm64)
build:
	docker buildx build --platform linux/amd64,linux/arm64 -t $(IMAGE) -f $(DOCKERFILE) --push .
	@echo ""
	@echo "Multi-arch image pushed: $(IMAGE)"

## build-local: Build the image with local tag for testing
build-local:
	docker build -t $(IMAGE_NAME):local -f $(DOCKERFILE) .
	@echo ""
	@echo "Image built: $(IMAGE_NAME):local"

## push: Push the image to registry (requires authentication)
push:
	@echo "Push is currently disabled - no registry permissions yet"
	@echo "To push manually: docker push $(IMAGE)"
	# docker push $(IMAGE)

## clean: Remove locally built images
clean:
	-docker rmi $(IMAGE) 2>/dev/null || true
	-docker rmi $(IMAGE_NAME):local 2>/dev/null || true
	@echo "Cleaned up local images"

## run: Run the image interactively for testing
run:
	docker run -it --rm $(IMAGE_NAME):local

## shell: Start a shell in the container for debugging
shell:
	docker run -it --rm --entrypoint /bin/zsh $(IMAGE_NAME):local

## help: Show this help message
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@sed -n 's/^## //p' $(MAKEFILE_LIST) | column -t -s ':' | sed 's/^/  /'
	@echo ""
	@echo "Variables:"
	@echo "  REGISTRY      Container registry (default: quay.io)"
	@echo "  ORGANIZATION  Organization/namespace (default: stolostron)"
	@echo "  IMAGE_NAME    Image name (default: code-agent)"
	@echo "  IMAGE_TAG     Image tag (default: latest)"
	@echo ""
	@echo "Examples:"
	@echo "  make build-local              # Build with local tag"
	@echo "  make build                    # Build with full registry path"
	@echo "  make IMAGE_TAG=v1.0.0 build   # Build with custom tag"
