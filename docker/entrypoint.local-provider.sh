#!/bin/sh
set -eu

state_dir="${LOCAL_PROVIDER_STATE_DIR:-/var/lib/lrail-provider}"
routes_dir="${LOCAL_PROVIDER_ROUTES_DIR:-/var/lib/lrail-routes}"
secret_file="${LOCAL_PROVIDER_SHARED_SECRET_FILE:-/run/lrail-provider-auth/secret}"
secret_dir="$(dirname "$secret_file")"

install -d -o appuser -g appgroup -m 0700 "$state_dir" "$secret_dir"
install -d -o appuser -g appgroup -m 0750 "$routes_dir"

if [ ! -s "$secret_file" ]; then
  temporary="${secret_file}.tmp.$$"
  umask 077
  python -c 'import secrets; print(secrets.token_urlsafe(48))' > "$temporary"
  chown appuser:appgroup "$temporary"
  mv "$temporary" "$secret_file"
fi

chown appuser:appgroup "$secret_file"
chmod 0600 "$secret_file"

exec gosu appuser "$@"
