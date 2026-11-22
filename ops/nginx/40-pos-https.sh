#!/bin/sh
# The name over HTTPS, switched on only while its certificate is there and
# nginx accepts it (ADR-098). Run by the nginx image's entrypoint before nginx
# starts, then watching: every POS_HTTPS_EVERY seconds, a certificate that
# appeared, was renewed or went away is taken by a reload, nginx never
# stopping. No name, a name that is not a hostname, no certificate, or one
# nginx refuses: the HTTPS server is not written, and HTTP keeps serving --
# a deploy never darkens the shop. tests/test_pos_https.py

POS_HOST="${POS_HOST:-}"
CONF="${POS_HTTPS_CONF:-/etc/nginx/conf.d/pos-https.conf}"
TEMPLATE="${POS_HTTPS_TEMPLATE:-/etc/nginx/pos-https.conf.template}"
CERTS="${POS_CERT_DIR:-/etc/letsencrypt/live/pos}"
NGINX="${NGINX_BIN:-nginx}"
EVERY="${POS_HTTPS_EVERY:-300}"

say() { echo "pos-https: $*"; }

# A hostname of lowercase labels, nothing else: it is written into the config.
hostname_ok() {
    [ -n "$1" ] || return 1
    [ "$(printf '%s' "$1" | wc -l)" -eq 0 ] || return 1
    printf '%s' "$1" | grep -Eqx '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+'
}

# What the switch depends on: the name and the certificate's files.
signature() {
    printf '%s|' "$POS_HOST"
    for f in "$CERTS/fullchain.pem" "$CERTS/privkey.pem"; do
        if [ -s "$f" ]; then
            stat -L -c '%Y.%s' "$f" 2>/dev/null || ls -lL "$f"
        else
            printf 'none'
        fi
        printf '|'
    done
}

# Write or remove the HTTPS server; 0 when it is on.
apply() {
    if [ -z "$POS_HOST" ]; then
        rm -f "$CONF"
        return 1
    fi
    if ! hostname_ok "$POS_HOST"; then
        say "POS_HOST is not a hostname -- HTTPS stays off"
        rm -f "$CONF"
        return 1
    fi
    if [ ! -s "$CERTS/fullchain.pem" ] || [ ! -s "$CERTS/privkey.pem" ]; then
        say "no certificate for $POS_HOST yet -- HTTP keeps serving"
        rm -f "$CONF"
        return 1
    fi
    sed "s/\${POS_HOST}/$POS_HOST/g" "$TEMPLATE" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
    if ! "$NGINX" -t >/dev/null 2>&1; then
        say "nginx refused the certificate for $POS_HOST -- HTTPS switched off, HTTP keeps serving"
        rm -f "$CONF"
        return 1
    fi
    say "HTTPS on for $POS_HOST"
    return 0
}

apply
[ -n "${POS_HTTPS_ONCE:-}" ] && exit 0

(
    last="$(signature)"
    while sleep "$EVERY"; do
        now="$(signature)"
        [ "$now" = "$last" ] && continue
        last="$now"
        apply
        "$NGINX" -s reload && say "reloaded"
    done
) &

exit 0
