#!/bin/sh
set -eu

host="${POSTGRES_HOST:-pgsql}"
port="${POSTGRES_PORT:-5432}"
user="${POSTGRES_USER:-devpush-app}"

printf "Waiting for PostgreSQL\n"
until pg_isready --host "$host" --port "$port" --username "$user" >/dev/null 2>&1; do
  sleep 1
done

printf "Preparing control-plane database\n"
bundle exec rails db:prepare
rm -f tmp/pids/server.pid

exec "$@"