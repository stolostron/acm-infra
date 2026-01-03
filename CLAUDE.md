# ACM Infra Project Instructions

## Code Agent Image

### Testing Phase Build & Push

When building and pushing the `code-agent` image, use the testing registry by default:

```bash
# Build the image
cd code-agent
make build REGISTRY=quay.io ORGANIZATION=zhaoxue IMAGE_NAME=code-agent IMAGE_TAG=latest

# Push to testing registry
docker push quay.io/zhaoxue/code-agent:latest
```

**Default testing image**: `quay.io/zhaoxue/code-agent:latest`

### Build Commands Reference

| Phase | Registry | Command |
|-------|----------|---------|
| Testing | `quay.io/zhaoxue/code-agent` | `make build REGISTRY=quay.io ORGANIZATION=zhaoxue` |
| Production | `quay.io/stolostron/code-agent` | `make build` (default Makefile settings) |

### Quick Commands

```bash
# Build and push (testing phase - default)
cd code-agent && make build REGISTRY=quay.io ORGANIZATION=zhaoxue && docker push quay.io/zhaoxue/code-agent:latest

# Build local only (for development)
cd code-agent && make build-local
```
