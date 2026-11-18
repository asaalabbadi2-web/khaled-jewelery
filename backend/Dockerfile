FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Asia/Riyadh

WORKDIR /app

# The backup tools are the database's major (tests/test_backup_tools_match_the_database.py):
# the distro's client is Debian 13's 17, and pg_restore 17 on the 16 server
# exits 1 on transaction_timeout -- the in-app restore said it failed and
# never restored the photos (the owner, 18 Nov 2026). From PostgreSQL's own
# repository, the major every compose file runs.
ARG PG_MAJOR=16

# System deps for psycopg2 + tzdata for timezone support
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      libpq-dev \
      postgresql-common \
      tzdata \
    && /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y \
    && apt-get install -y --no-install-recommends postgresql-client-${PG_MAJOR} \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
    && echo $TZ > /etc/timezone \
    && rm -rf /var/lib/apt/lists/*

# Install python deps first (better layer caching)
COPY backend/requirements.txt /app/backend/requirements.txt
RUN pip install --no-cache-dir -r /app/backend/requirements.txt

# Copy backend source — ARG here forces cache-bust when BUILD_DATE changes
ARG BUILD_DATE=unknown
COPY backend /app/backend

EXPOSE 8001

# Default: run via gunicorn (production)
CMD ["gunicorn", "-c", "backend/gunicorn.conf.py", "backend.wsgi:app"]
