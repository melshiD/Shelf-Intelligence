# Monorepo: Laravel 11 + FastAPI (Render-ready)

This repository contains a monorepo for deploying to Render with:
- app: Laravel 11 web app (Breeze, queues, upload flow, overlays)
- cv-analyzer: Python 3.11 FastAPI service (health/version + analyze pipeline skeleton)
- render.yaml: Render Blueprint defining services and managed Postgres + Redis

## Quick start (local)

- Python service:
  - cd `cv-analyzer`
  - Create venv and install: `python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt`
  - Run: `uvicorn main:app --host 0.0.0.0 --port 8000`
  - Health: GET http://localhost:8000/healthz, Version: GET http://localhost:8000/version

- Laravel app (requires PHP 8.2+, Composer, Node 18+):
  - cd `app`
  - Run bootstrap: `bash scripts/bootstrap.sh`
  - Copy `.env.example` to `.env` and set required vars
  - Run server: `php artisan serve`
  - Health: GET http://localhost:8000/healthz
  - Queue worker: `php artisan queue:work --sleep=1 --tries=3`

## Env variables (.env)

- DATABASE_URL, REDIS_URL
- FILESYSTEM_DISK=s3
- AWS_ENDPOINT (Supabase S3 URL), AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION=us-east-1, AWS_BUCKET
- TMDB_API_KEY, OMDB_API_KEY, OPENAI_API_KEY (optional)
- CV_ANALYZER_URL (e.g. http://localhost:8000 for local FastAPI)

## End-to-end flow

- Auth via Breeze; upload a photo at `/photos`
- Enqueues `AnalyzePhoto` -> calls `cv-analyzer` POST `/analyze` with a signed S3 URL
- Items are persisted and visualized with canvas overlays; watchlist UI stubs provided

## Render deployment

- Push this repo and open the Render Blueprint at the repo root
- Render provisions:
  - `dvdapp-web` (PHP web) — runs migrations and serves app
  - `dvdapp-worker` (PHP worker) — runs `php artisan queue:work`
  - `cv-analyzer` (Dockerized FastAPI) — exposes `/healthz` and `/version`
  - Managed Postgres + Redis
- Set S3-compatible envs for Supabase: `AWS_ENDPOINT`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_BUCKET`
- Configure API keys for TMDb/OMDb/OpenAI as needed

## Notes

- The analyzer includes a fallback path if heavy CV libs are not available; still returns a valid schema.
- Title matching/enrichment/jobs are stubbed to keep costs low; structure is ready to extend.