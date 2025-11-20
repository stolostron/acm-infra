#!/usr/bin/env bash

set -euo pipefail

# Build and push script for Konflux Compliance Scanner Docker image
# Usage: ./build-and-push.sh [options]

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
IMAGE_REGISTRY="${IMAGE_REGISTRY:-quay.io}"
IMAGE_ORG="${IMAGE_ORG:-your-org}"
IMAGE_NAME="${IMAGE_NAME:-compliance-scanner}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
BUILD_TOOL="${BUILD_TOOL:-docker}"
PLATFORM="${PLATFORM:-linux/amd64}"
PUSH="${PUSH:-true}"
VERSION_FILE="VERSION"

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Build and push Konflux Compliance Scanner Docker image.

OPTIONS:
    --registry REGISTRY     Container registry (default: quay.io)
    --org ORG               Organization/username (default: your-org)
    --name NAME             Image name (default: compliance-scanner)
    --tag TAG               Image tag (default: latest)
    --tool TOOL             Build tool: docker or podman (default: docker)
    --platform PLATFORM     Target platform (default: linux/amd64)
                            Use 'multi' for multiarch (linux/amd64,linux/arm64)
    --no-push               Build only, do not push to registry
    --version VERSION       Set version tag (also creates 'latest' tag)
    -h, --help              Show this help message

EXAMPLES:
    # Build and push with defaults
    $(basename "$0")

    # Build for specific organization
    $(basename "$0") --org mycompany --tag v1.0.0

    # Build multiarch image
    $(basename "$0") --platform multi --tag v1.0.0

    # Build only (no push)
    $(basename "$0") --no-push

    # Use podman instead of docker
    $(basename "$0") --tool podman

    # Full custom example
    $(basename "$0") \\
        --registry quay.io \\
        --org acm-team \\
        --name compliance-scanner \\
        --tag v1.2.3 \\
        --platform multi

ENVIRONMENT VARIABLES:
    IMAGE_REGISTRY          Container registry URL
    IMAGE_ORG               Organization/username
    IMAGE_NAME              Image name
    IMAGE_TAG               Image tag
    BUILD_TOOL              Build tool (docker or podman)
    PLATFORM                Target platform

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --registry)
            IMAGE_REGISTRY="$2"
            shift 2
            ;;
        --org)
            IMAGE_ORG="$2"
            shift 2
            ;;
        --name)
            IMAGE_NAME="$2"
            shift 2
            ;;
        --tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --tool)
            BUILD_TOOL="$2"
            shift 2
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --no-push)
            PUSH=false
            shift
            ;;
        --version)
            VERSION_TAG="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# Construct full image name
FULL_IMAGE="${IMAGE_REGISTRY}/${IMAGE_ORG}/${IMAGE_NAME}"
FULL_IMAGE_TAG="${FULL_IMAGE}:${IMAGE_TAG}"

# Handle multiarch platform
if [[ "$PLATFORM" == "multi" ]]; then
    PLATFORM="linux/amd64,linux/arm64"
    MULTIARCH=true
else
    MULTIARCH=false
fi

echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}Konflux Compliance Scanner - Build & Push${NC}"
echo -e "${BLUE}=================================================${NC}"
echo ""
echo -e "${BLUE}Configuration:${NC}"
echo -e "  Registry:    ${IMAGE_REGISTRY}"
echo -e "  Organization: ${IMAGE_ORG}"
echo -e "  Image Name:  ${IMAGE_NAME}"
echo -e "  Tag:         ${IMAGE_TAG}"
echo -e "  Full Image:  ${FULL_IMAGE_TAG}"
echo -e "  Build Tool:  ${BUILD_TOOL}"
echo -e "  Platform(s): ${PLATFORM}"
echo -e "  Push:        ${PUSH}"
if [[ -n "${VERSION_TAG:-}" ]]; then
    echo -e "  Version:     ${VERSION_TAG}"
fi
echo ""

# Validate build tool
if ! command -v "$BUILD_TOOL" &> /dev/null; then
    echo -e "${RED}ERROR: Build tool '$BUILD_TOOL' not found${NC}"
    echo "Please install $BUILD_TOOL or use --tool to specify an alternative"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Validate required files
echo -e "${BLUE}Validating required files...${NC}"
# Note: compliance.sh, create-compliance-jira-issues.sh, and component-squad.yaml
# are fetched from stolostron/installer-dev-tools repo during Docker build
required_files=(
    "Dockerfile"
    "entrypoint.sh"
)

missing_files=()
for file in "${required_files[@]}"; do
    if [[ ! -f "$file" ]]; then
        missing_files+=("$file")
    else
        echo -e "${GREEN}✓${NC} $file"
    fi
done

if [[ ${#missing_files[@]} -gt 0 ]]; then
    echo -e "${RED}ERROR: Missing required files:${NC}"
    printf '  - %s\n' "${missing_files[@]}"
    exit 1
fi

echo -e "${GREEN}✓${NC} Scripts will be fetched from stolostron/installer-dev-tools during build"

# Write version file if VERSION_TAG is set
if [[ -n "${VERSION_TAG:-}" ]]; then
    echo "$VERSION_TAG" > "$VERSION_FILE"
    echo -e "${GREEN}✓${NC} Created $VERSION_FILE with version $VERSION_TAG"
fi

echo ""

# Build image
echo -e "${BLUE}Building Docker image...${NC}"
echo ""

if [[ "$BUILD_TOOL" == "docker" ]]; then
    if [[ "$MULTIARCH" == "true" ]]; then
        # Multiarch build with buildx
        echo "Using Docker buildx for multiarch build..."

        # Create builder if needed
        if ! docker buildx ls | grep -q "multiarch-builder"; then
            echo "Creating multiarch builder..."
            docker buildx create --name multiarch-builder --use
            docker buildx inspect --bootstrap
        else
            echo "Using existing multiarch builder..."
            docker buildx use multiarch-builder
            # Ensure builder is running
            docker buildx inspect --bootstrap
        fi

        # Build command
        BUILD_CMD=(
            docker buildx build
            --platform "$PLATFORM"
            -t "$FULL_IMAGE_TAG"
        )

        # Add version tag if specified
        if [[ -n "${VERSION_TAG:-}" ]]; then
            BUILD_CMD+=(-t "${FULL_IMAGE}:${VERSION_TAG}")
            BUILD_CMD+=(-t "${FULL_IMAGE}:latest")
        fi

        # Add push flag
        if [[ "$PUSH" == "true" ]]; then
            BUILD_CMD+=(--push)
        else
            BUILD_CMD+=(--load)
        fi

        BUILD_CMD+=(.)

    else
        # Standard single-arch build
        BUILD_CMD=(
            docker build
            --platform "$PLATFORM"
            -t "$FULL_IMAGE_TAG"
        )

        # Add version tag if specified
        if [[ -n "${VERSION_TAG:-}" ]]; then
            BUILD_CMD+=(-t "${FULL_IMAGE}:${VERSION_TAG}")
            BUILD_CMD+=(-t "${FULL_IMAGE}:latest")
        fi

        BUILD_CMD+=(.)
    fi

elif [[ "$BUILD_TOOL" == "podman" ]]; then
    # Podman build
    BUILD_CMD=(
        podman build
        --platform "$PLATFORM"
        -t "$FULL_IMAGE_TAG"
    )

    # Add version tag if specified
    if [[ -n "${VERSION_TAG:-}" ]]; then
        BUILD_CMD+=(-t "${FULL_IMAGE}:${VERSION_TAG}")
        BUILD_CMD+=(-t "${FULL_IMAGE}:latest")
    fi

    BUILD_CMD+=(.)
fi

# Execute build
echo "Executing: ${BUILD_CMD[*]}"
echo ""

if "${BUILD_CMD[@]}"; then
    echo ""
    echo -e "${GREEN}✓ Image built successfully${NC}"
else
    echo ""
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi

# Push image (if not already pushed by buildx)
if [[ "$PUSH" == "true" && "$MULTIARCH" == "false" ]]; then
    echo ""
    echo -e "${BLUE}Pushing image to registry...${NC}"
    echo ""

    # Login check
    if [[ "$BUILD_TOOL" == "docker" ]]; then
        if ! docker info 2>/dev/null | grep -q "Registry: $IMAGE_REGISTRY"; then
            echo -e "${YELLOW}Warning: Not logged in to $IMAGE_REGISTRY${NC}"
            echo "Run: docker login $IMAGE_REGISTRY"
            echo ""
            read -p "Do you want to continue? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi

    # Push main tag
    if [[ "$BUILD_TOOL" == "docker" ]]; then
        docker push "$FULL_IMAGE_TAG"
    else
        podman push "$FULL_IMAGE_TAG"
    fi

    # Push version tags if specified
    if [[ -n "${VERSION_TAG:-}" ]]; then
        if [[ "$BUILD_TOOL" == "docker" ]]; then
            docker push "${FULL_IMAGE}:${VERSION_TAG}"
            docker push "${FULL_IMAGE}:latest"
        else
            podman push "${FULL_IMAGE}:${VERSION_TAG}"
            podman push "${FULL_IMAGE}:latest"
        fi
    fi

    echo ""
    echo -e "${GREEN}✓ Image pushed successfully${NC}"
fi

# Summary
echo ""
echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}Build Summary${NC}"
echo -e "${BLUE}=================================================${NC}"
echo ""
echo -e "${GREEN}Image built:${NC}"
echo -e "  ${FULL_IMAGE_TAG}"

if [[ -n "${VERSION_TAG:-}" ]]; then
    echo -e "  ${FULL_IMAGE}:${VERSION_TAG}"
    echo -e "  ${FULL_IMAGE}:latest"
fi

if [[ "$PUSH" == "true" ]]; then
    echo ""
    echo -e "${GREEN}Image pushed to:${NC} ${IMAGE_REGISTRY}"
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo "1. Update cronjob.yaml with the image:"
    echo -e "   ${YELLOW}image: ${FULL_IMAGE_TAG}${NC}"
    echo ""
    echo "2. Deploy to Kubernetes:"
    echo -e "   ${YELLOW}kubectl apply -f cronjob.yaml${NC}"
else
    echo ""
    echo -e "${YELLOW}Image not pushed (--no-push flag set)${NC}"
    echo ""
    echo -e "${BLUE}To push manually:${NC}"
    echo -e "   ${BUILD_TOOL} push ${FULL_IMAGE_TAG}"
fi

echo ""
echo -e "${GREEN}Done!${NC}"
