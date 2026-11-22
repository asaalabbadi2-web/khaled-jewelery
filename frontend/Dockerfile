# Multi-stage build: Flutter Web -> Nginx
# Produces a self-contained image that serves Flutter Web and proxies /api to backend.

# 1) Build Flutter web
ARG FLUTTER_IMAGE=ghcr.io/cirruslabs/flutter:3.35.4
FROM ${FLUTTER_IMAGE} AS build

WORKDIR /app

# Copy pubspec first for better caching
COPY frontend/pubspec.yaml frontend/pubspec.lock* /app/
RUN flutter pub get

# Copy the rest of the frontend
COPY frontend /app

# Compile-time API base URL for the web app (ApiService reads dart-define API_BASE_URL)
ARG API_BASE_URL=/api

# Compile-time Google OAuth Web Client ID for google_sign_in_web
# (used by GoogleDriveBackupService on web)
ARG GOOGLE_WEB_CLIENT_ID=

# --pwa-strategy none (the owner, 21 Nov 2026): no service worker keeping a
# build on the device -- every device on the deployed build at its next load;
# the handheld reader kept an old one until its site data was cleared.
# --no-web-resources-cdn (the owner, 22 Nov 2026): the rendering engine served
# by our server, not fetched from www.gstatic.com -- with the shop's internet
# cut, the app must still start at its internal address (ADR-098).
RUN flutter build web --release --no-tree-shake-icons --pwa-strategy none --no-web-resources-cdn \
	--dart-define=API_BASE_URL=${API_BASE_URL} \
	--dart-define=GOOGLE_WEB_CLIENT_ID=${GOOGLE_WEB_CLIENT_ID}

# 2) Serve with nginx
FROM nginx:1.27-alpine

COPY ops/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY ops/nginx/app.conf /etc/nginx/snippets/app.conf
# The name over HTTPS (ADR-098): the template, and the switch the image's
# entrypoint runs before nginx starts -- on only with its certificate.
COPY ops/nginx/pos-https.conf.template /etc/nginx/pos-https.conf.template
COPY ops/nginx/40-pos-https.sh /docker-entrypoint.d/40-pos-https.sh
RUN chmod 755 /docker-entrypoint.d/40-pos-https.sh
COPY --from=build /app/build/web /usr/share/nginx/html

EXPOSE 80 443
