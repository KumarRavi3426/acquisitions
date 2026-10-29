#!/bin/bash

# Development startup script for Acquisition App with Neon Local
# This script starts the application in development mode with Neon Local

set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
cd "$PROJECT_ROOT"

echo "🚀 Starting Acquisition App in Development Mode"
echo "================================================"

# Check if .env.development exists
if [ ! -f .env.development ]; then
    echo "❌ Error: .env.development file not found!"
    echo "   Please copy .env.development from the template and update with your Neon credentials."
    exit 1
fi

# Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    echo "❌ Error: Docker is not running!"
    echo "   Please start Docker Desktop and try again."
    exit 1
fi

# Create .neon_local directory if it doesn't exist
mkdir -p .neon_local

# Add .neon_local to .gitignore if not already present
if ! grep -q ".neon_local/" .gitignore 2>/dev/null; then
    echo ".neon_local/" >> .gitignore
    echo "✅ Added .neon_local/ to .gitignore"
fi

echo "📦 Building and starting development containers..."
echo "   - Neon Local proxy will create an ephemeral database branch"
echo "   - Application will run with hot reload enabled"
echo ""

# Start development environment (neon-local first, then app)
echo "📦 Starting containers..."
docker compose -f docker-compose.dev.yml up -d neon-local

# Wait for neon-local to be healthy before running migrations
echo "⏳ Waiting for the database to be ready..."
docker compose -f docker-compose.dev.yml exec neon-local sh -c 'until pg_isready -h localhost -p 5432 -U neon; do sleep 2; done'

# Run migrations with Drizzle inside the container (so localhost resolves correctly)
echo "📜 Applying latest schema with Drizzle..."
docker compose -f docker-compose.dev.yml exec -e DATABASE_URL="postgres://neon:npg@localhost:5432/neondb?sslmode=require" neon-local sh -c 'cd /app && npm run db:migrate' 2>/dev/null || npm run db:migrate

# Start remaining services
docker compose -f docker-compose.dev.yml up --build

echo ""
echo "🎉 Development environment started!"
echo "   Application: http://localhost:3000"
echo "   Database: postgres://neon:npg@localhost:5432/neondb"
echo ""
echo "To stop the environment, press Ctrl+C or run: docker compose down"