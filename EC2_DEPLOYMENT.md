# Deploying Acquisitions on Amazon EC2

This application runs as a Node.js container and uses Neon PostgreSQL. The
steps below deploy one production container on an Ubuntu EC2 instance.

## 1. Create the EC2 instance

Use an Ubuntu 24.04 LTS instance (a `t3.small` or larger is a reasonable
starting point). Configure the security group with:

- TCP 22 from your IP address only (SSH)
- TCP 80 from `0.0.0.0/0` (HTTP)
- TCP 443 from `0.0.0.0/0` (HTTPS, when TLS is configured)

Do not expose port 3000 publicly. The compose file binds the application to
the instance loopback interface.

## 2. Install Docker and download the deployment files

SSH into the instance, then run:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
newgrp docker

git clone https://github.com/KumarRavi3426/acquisitions.git
cd acquisitions
```

The repository is needed for `docker-compose.prod.yml`, `scripts/prod.sh`, and
the environment template. The application source code is not built on EC2.
For a private Docker Hub repository, log in on EC2 before deployment:

```bash
docker login
```

## 3. Configure production secrets

Create the environment file only on the EC2 instance:

```bash
cp .env.production.example .env.production
chmod 600 .env.production
nano .env.production
```

Set at least these values:

```dotenv
NODE_ENV=production
PORT=3000
LOG_LEVEL=info
DATABASE_URL=postgresql://...
JWT_SECRET=<long-random-secret>
ARCJET_KEY=<arcjet-key>
CORS_ORIGIN=https://your-domain.example
```

Also set these Docker Hub image values:

```dotenv
IMAGE_REPOSITORY=your-dockerhub-username/acquisitions
IMAGE_TAG=latest
MIGRATION_IMAGE_TAG=migration-latest
```

`DATABASE_URL` must be a Neon PostgreSQL connection string with SSL enabled
(for example, `?sslmode=require`). `NEON_API_KEY`, `NEON_PROJECT_ID`,
`PARENT_BRANCH_ID`, and `DELETE_BRANCH` are only needed for Neon Local
development and are not required on EC2.

## 4. Pull, migrate, and start

The production script loads `.env.production`, pulls both images from Docker
Hub, runs the database migration, and starts the application container:

```bash
chmod +x scripts/prod.sh
bash scripts/prod.sh
docker compose --env-file .env.production -f docker-compose.prod.yml ps
curl http://127.0.0.1:3000/health
```

The application should return a JSON health response. View logs with:

```bash
docker logs -f acquisitions-app-prod
```

On later releases:

```bash
git pull
bash scripts/prod.sh
```

To deploy a specific published version, change `IMAGE_TAG` in
`.env.production` (for example, `main-abc1234`) and run the script again.

## 5. Put the API behind HTTPS

Point your DNS A record at the EC2 Elastic IP, then configure an HTTPS reverse
proxy such as Nginx or Caddy to forward requests to
`http://127.0.0.1:3000`. Only the reverse proxy should be internet-facing.
Set `CORS_ORIGIN` to the exact frontend origin, not `*`.

## Operations

```bash
# Follow application logs
docker logs -f acquisitions-app-prod

# Restart after an instance reboot or configuration change
docker compose --env-file .env.production -f docker-compose.prod.yml up -d

# Stop the application
docker compose --env-file .env.production -f docker-compose.prod.yml down
```

Back up Neon separately; the EC2 container does not provide database
persistence. Rotate `JWT_SECRET`, `ARCJET_KEY`, and database credentials using
AWS Systems Manager Parameter Store or Secrets Manager for a production
pipeline rather than storing them in shell history.
