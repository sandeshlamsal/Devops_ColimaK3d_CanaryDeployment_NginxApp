FROM nginx:1.25-alpine

ARG APP_VERSION=unknown
ARG BUILD_ENV=stable

# Copy env-specific config
COPY ${BUILD_ENV}.conf /etc/nginx/conf.d/default.conf

# Embed version into a static file for health/version checks
RUN echo "${APP_VERSION}" > /usr/share/nginx/html/version.txt

EXPOSE 80

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost/healthz || exit 1
