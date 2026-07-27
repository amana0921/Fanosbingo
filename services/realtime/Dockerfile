# Supabase Realtime.
#
# VERSION: 2.120.0, not the 2.34.x line.
#
# 2.34.47 has NO TLS support for its PostgreSQL connection -- no DB_SSL setting,
# and no ssl references anywhere in its runtime configuration. That is fatal
# here rather than merely unfortunate, because RDS PostgreSQL 15+ ships with
# rds.force_ssl = 1 as the ENGINE DEFAULT. The database refuses the connection
# outright:
#
#   FATAL 28000 (invalid_authorization_specification)
#   no pg_hba.conf entry for host "10.30.0.240", user "app_service",
#   database "fanosbingo", no encryption
#
# The workaround would have been setting rds.force_ssl = 0, weakening every
# connection to the database for the sake of one client. 2.120.0 adds DB_SSL
# and DB_SSL_CA_CERT, so the enforcement stays on and this connection is
# verified rather than merely encrypted.
#
# DB_SSL_CA_CERT is a FILE PATH (Erlang's :cacertfile), not inline PEM. Note
# from the source that DB_SSL=true WITHOUT a CA falls back to
# `verify: :verify_none` -- encrypted but unverified -- so supplying this path
# is what makes verification actually happen.
#
# Mirrored into ECR rather than pulled from Docker Hub at task start:
# anonymous pulls are rate-limited per source IP, and a task restarting inside
# a rate-limit window cannot start at all.
#
# BUILD CONTEXT IS THE REPOSITORY ROOT:
#   docker build -f services/realtime/Dockerfile .

FROM docker.io/supabase/realtime:v2.120.0

COPY docker/rds-global-bundle.pem /opt/rds-global-bundle.pem
