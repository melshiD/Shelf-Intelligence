# Monorepo: Laravel 11 + FastAPI (Render-ready)

This repository contains a minimal monorepo for deploying to Render with:
- app: Laravel 11 web app (Breeze, queues, stub pages)
- cv-analyzer: Python 3.11 FastAPI service (health + dummy analyze)
- render.yaml: Render Blueprint defining services and managed Postgres + Redis

## Quick start (local)

- Python service:
  - cd `cv-analyzer`
  - Create venv and install: `python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt`
  - Run: `uvicorn main:app --host 0.0.0.0 --port 8000`
  - Health: GET http://localhost:8000/healthz

- Laravel app (requires PHP 8.2+, Composer, Node 18+):
  - cd `app`
  - Run bootstrap: `bash scripts/bootstrap.sh`
  - Copy `.env.example` to `.env` and set required vars
  - Run server: `php artisan serve`
  - Health: GET http://localhost:8000/healthz
  - Queue worker: `php artisan queue:work --sleep=1 --tries=3`

## Env variables (.env)

- DATABASE_URL
- REDIS_URL
- FILESYSTEM_DISK=s3
- AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION, AWS_BUCKET
- TMDB_API_KEY, OMDB_API_KEY
- CV_ANALYZER_URL (e.g. http://localhost:8000 for local FastAPI)

## Render deployment

- Push this repo to GitHub and open the Render Blueprint at the repo root
- Render will detect `render.yaml` and provision:
  - `dvdapp-web` (PHP web)
  - `dvdapp-worker` (PHP worker)
  - `cv-analyzer` (Dockerized FastAPI)
  - Managed Postgres + Redis
- The `dvdapp-web` and worker build run `app/scripts/bootstrap.sh` to set up Laravel and Breeze, run migrations, and build assets.
- After deploy, visit `/healthz` on the web URL and on the cv-analyzer service.

## Notes

- Business logic is stubbed. The `Photos` pages and `AnalyzePhoto` job are no-ops.
- `App\Services\CvAnalyzer` checks the FastAPI `/healthz`. `App\Services\Tmdb` exposes a ping helper.