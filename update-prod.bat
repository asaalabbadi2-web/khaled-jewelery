@echo off
echo ============================================
echo   Khaled-Jewelery Production Update
echo ============================================
cd /d "C:\Khaled-Jewelery"

REM === Production runs on the GitLab Container Registry, so this script uses
REM    docker-compose.prod.gitlab.yml -- the only compose file whose image
REM    references actually match it (registry.gitlab.com/sasalabbadi/khaledjewels).
REM    docker-compose.prod.images.yml points at ghcr.io and belongs to the
REM    GitHub Actions path instead; using it here meant the registry login and
REM    the image references disagreed.
REM    One variable, so there is a single place to change the compose file.
set COMPOSE_FILE_NAME=docker-compose.prod.gitlab.yml
set COMPOSE=docker compose -f %COMPOSE_FILE_NAME% --env-file .env.production

echo.
echo [1/5] Logging into GitLab Registry...
set GL_TOKEN=YOUR_TOKEN_HERE
echo %GL_TOKEN% | docker login registry.gitlab.com -u sasalabbadi --password-stdin
if %ERRORLEVEL% neq 0 (
    echo ERROR: Docker login failed!
    pause & exit /b 1
)

echo.
echo [2/5] Pulling latest images from GitLab...
%COMPOSE% pull
if %ERRORLEVEL% neq 0 (
    echo ERROR: Pull failed!
    pause & exit /b 1
)

REM === Migrations run BEFORE the app starts, and a failure here aborts the
REM    deploy. Two reasons this order is mandatory, both learned the hard way:
REM      1. backend/app.py calls db.create_all() at import time (for gunicorn),
REM         so if the app boots first it creates tables straight from the models
REM         and alembic then finds them already present. The schema looks right
REM         while alembic_version stays behind and data-carrying steps such as a
REM         backfill silently never run -- exactly what happened to the Phase 16C
REM         deploy (tables present, 0 of 153 obligations backfilled).
REM      2. A half-migrated schema must never serve traffic.
REM    `run --rm` is used rather than `exec` so this does not depend on the app
REM    container being up yet; compose starts db first and waits for its
REM    healthcheck via backend's depends_on: service_healthy.
echo.
echo [3/5] Applying database migrations...
%COMPOSE% run --rm backend bash -c "cd /app/backend && alembic upgrade head"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Migration failed - DEPLOY ABORTED. Services were NOT restarted.
    echo The previous version is still running. Read the error above before retrying.
    pause & exit /b 1
)
%COMPOSE% run --rm backend bash -c "cd /app/backend && alembic current"

echo.
echo [4/5] Restarting all services (including scheduler)...
%COMPOSE% up -d --force-recreate
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to start services!
    pause & exit /b 1
)

echo.
echo [5/5] Verifying scheduler started correctly...
timeout /t 5 /nobreak > nul
docker logs yasargold-scheduler --tail=15

echo.
echo ============================================
echo   Update Complete!
echo ============================================
pause
