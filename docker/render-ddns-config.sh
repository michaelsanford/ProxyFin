#!/bin/sh
set -eu

: "${DOMAIN:?DOMAIN is required}"
: "${SUBDOMAIN:?SUBDOMAIN is required}"
: "${HOSTED_ZONE_ID:?HOSTED_ZONE_ID is required}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"

# Defaults to dual-stack; set IP_VERSION=ipv4 or IP_VERSION=ipv6 in .env to
# publish only one record type (e.g. to work around a flaky IPv6 uplink).
export IP_VERSION="${IP_VERSION:-ipv4 or ipv6}"

TEMPLATE_PATH="${TEMPLATE_PATH:-/template/ddns.json.template}"
OUTPUT_PATH="${OUTPUT_PATH:-/output/config.json}"

envsubst '${DOMAIN} ${SUBDOMAIN} ${HOSTED_ZONE_ID} ${AWS_ACCESS_KEY_ID} ${AWS_SECRET_ACCESS_KEY} ${IP_VERSION}' \
    < "$TEMPLATE_PATH" > "$OUTPUT_PATH"

echo "Rendered DDNS config to $OUTPUT_PATH"
