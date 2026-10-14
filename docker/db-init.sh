#!/bin/sh
# One-shot, run by the db-init service on every `docker compose up`.
# Creates the "app" role and database if they are missing and applies db/schema.sql
# (idempotent). Never changes the password of an existing role.
set -eu
: "${APP_DB_PASSWORD:?set APP_DB_PASSWORD in .env}"

psql -v ON_ERROR_STOP=1 -q -d n8n -v pw="$APP_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE app LOGIN PASSWORD %L', :'pw')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app') \gexec
SELECT 'CREATE DATABASE app OWNER app'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'app') \gexec
SQL

psql -v ON_ERROR_STOP=1 -q -d app -c 'SET client_min_messages = warning' -f /db/schema.sql
echo "[db-init] database app is ready"
