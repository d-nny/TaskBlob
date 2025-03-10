#!/bin/bash
# Fix for nginx container issues

# Stop and remove nginx container if it exists
echo "Removing nginx container if it exists..."
docker rm -f nginx || true

# Remove nginx image
echo "Removing nginx image..."
docker rmi nginx:latest || true

# Clean up any stale containers
echo "Pruning stopped containers..."
docker container prune -f

# Rebuild and restart everything
echo "Restarting all services..."
docker-compose down
docker-compose up -d

echo "Done. Check if all services are running with: docker ps"
