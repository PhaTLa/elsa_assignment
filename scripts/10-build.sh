#!/bin/bash
set -eu

# Load environment variables
if [ -f .env ]; then
  export $(cat .env | xargs)
fi

GITHUB_USERNAME=${GITHUB_USERNAME:-PhaTLa}
GHCR_TOKEN=${GHCR_TOKEN}
REGISTRY="ghcr.io"

if [ -z "$GHCR_TOKEN" ]; then
  echo "ERROR: GHCR_TOKEN not set in .env"
  exit 1
fi

# Convert username to lowercase for GHCR
GHCR_USERNAME=$(echo "$GITHUB_USERNAME" | tr '[:upper:]' '[:lower:]')

# Get git SHA
GIT_SHA=$(git rev-parse --short HEAD)
IMAGE_TAG="${REGISTRY}/${GHCR_USERNAME}/quote-api:${GIT_SHA}"

echo "=== Quote API Build & Push ==="
echo "Git SHA: ${GIT_SHA}"
echo "Image: ${IMAGE_TAG}"

# Login to GHCR (idempotent - logs in every time, but harmless)
echo "Authenticating to GHCR..."
echo "$GHCR_TOKEN" | docker login "$REGISTRY" -u "$GHCR_USERNAME" --password-stdin >/dev/null 2>&1

# Check if image already exists locally
if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  echo "✓ Image already built locally: ${IMAGE_TAG}"
else
  echo "Building image..."
  cd app
  docker build -t "$IMAGE_TAG" .
  cd ..
  echo "✓ Image built: ${IMAGE_TAG}"
fi

# Check if image already exists in GHCR (idempotent push skip)
if docker pull "$IMAGE_TAG" >/dev/null 2>&1; then
  echo "✓ Image already in GHCR, skipping push"
else
  echo "Pushing image to GHCR..."
  docker push "$IMAGE_TAG"
  echo "✓ Image pushed: ${IMAGE_TAG}"
fi

echo ""
echo "=== Build Complete ==="
echo "Image available: ${IMAGE_TAG}"
