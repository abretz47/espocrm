# ─── Build stage: compile frontend assets ────────────────────────────────────
FROM node:20-alpine AS frontend-builder

WORKDIR /build

# Install only the files needed to resolve npm dependencies first,
# so Docker can cache this layer when source files are unchanged.
COPY package.json package-lock.json ./
RUN PUPPETEER_SKIP_DOWNLOAD=1 CHROMEDRIVER_SKIP_DOWNLOAD=true \
    npm ci --ignore-scripts 2>/dev/null || \
    npm install --ignore-scripts

# Copy the rest of the source and build the frontend bundle.
COPY . .
RUN npm run build-frontend


# ─── Runtime stage ───────────────────────────────────────────────────────────
FROM php:8.3-fpm-alpine

# Install system packages required by PHP extensions and nginx.
#
# Strategy to avoid multiple apk network calls (which hit transient DNS failures):
# 1. Run `apk update` once (with retries) to cache the package index locally.
# 2. Install all packages without --no-cache so the cached index is reused.
# 3. Pre-create the exact virtual-group name that docker-php-ext-configure /
#    docker-php-ext-install would create themselves (based on phpize's version
#    hash). Those scripts check for the group with `apk info --installed` first;
#    finding it already present, they skip their own `apk add --no-cache`, which
#    is the call that causes the second DNS lookup and intermittent failures.
# 4. docker-php-ext-install removes the virtual group during its own cleanup, so
#    we only need to remove the -dev header packages ourselves.
RUN for i in 1 2 3; do apk update && break || sleep 5; done \
    && PHPIZE_HASH="$(phpize --version | sha1sum | cut -c1-8)" \
    && apk add \
        nginx \
        git \
        unzip \
        libpng-dev \
        libjpeg-turbo-dev \
        freetype-dev \
        libzip-dev \
        libxml2-dev \
        curl-dev \
        oniguruma-dev \
        gettext-dev \
        icu-dev \
    && apk add --virtual ".phpize-deps-configure-${PHPIZE_HASH}" $PHPIZE_DEPS \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo \
        pdo_mysql \
        pdo_pgsql \
        gd \
        zip \
        mbstring \
        xml \
        dom \
        curl \
        exif \
        opcache \
        ctype \
        openssl \
        intl \
    && apk del \
        libpng-dev libjpeg-turbo-dev freetype-dev \
        libzip-dev libxml2-dev curl-dev oniguruma-dev \
        gettext-dev icu-dev \
    && rm -rf /var/cache/apk/*

# Install Composer.
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Copy application source.
WORKDIR /var/www/html
COPY . .

# Copy compiled frontend assets from the build stage.
COPY --from=frontend-builder /build/client/lib  ./client/lib
COPY --from=frontend-builder /build/client/css  ./client/css

# Install PHP dependencies (production only).
RUN composer install --no-dev --optimize-autoloader --no-interaction --no-progress

# Configure nginx.
COPY docker/nginx.conf /etc/nginx/http.d/default.conf

# Configure PHP-FPM to listen on a TCP port so nginx can reach it.
RUN sed -i 's|listen = .*|listen = 127.0.0.1:9000|' /usr/local/etc/php-fpm.d/www.conf

# Create writable directories and set ownership.
RUN mkdir -p data/logs data/cache data/upload data/tmp \
    && chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html \
    && chmod -R 775 data client custom

# Expose the HTTP port.
EXPOSE 80

# Copy and set the entrypoint script.
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
