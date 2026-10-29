#!/bin/bash

# Production deployment script for Acquisition App
# This script starts the application in production mode with Neon Cloud Database

set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
cd "$PROJECT_ROOT"

echo "🚀 Starting Acquisition App in Production Mode"
echo "==============================================="

# Check if .env.production exists
if [ ! -f .env.production ]; then
    echo "❌ Error: .env.production file not found!"
    echo "   Please create .env.production with your production environment variables."
    exit 1
fi

# Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    echo "❌ Error: Docker is not running!"
    echo "   Please start Docker and try again."
    exit 1
fi

echo "📦 Pulling production containers..."
echo "   - Using Neon Cloud Database (no local proxy)"
echo "   - Pulling application and migration images from Docker Hub"
echo ""

compose() {
    docker compose --env-file .env.production -f docker-compose.prod.yml "$@"
}

# Pull the immutable application and migration images before changing the database.
compose pull

# Run migrations with Drizzle
echo "📜 Applying latest schema with Drizzle..."
compose run --rm migration

# Start production environment after migrations complete.
echo "🚀 Starting production container..."
compose up -d

echo ""
echo "🎉 Production environment started!"
echo "   Application: http://localhost:3000"
echo "   Logs: docker logs acquisitions-app-prod"
echo ""
echo "Useful commands:"
echo "   View logs: docker logs -f acquisitions-app-prod"
echo "   Stop app: docker compose --env-file .env.production -f docker-compose.prod.yml down"