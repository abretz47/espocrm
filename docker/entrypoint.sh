#!/bin/sh
set -e

# Start PHP-FPM in the background.
php-fpm -D

# Start nginx in the foreground so the container stays alive.
exec nginx -g "daemon off;"
