# PostgREST, with Amazon's RDS CA bundle layered on.
#
# The upstream image has no reason to trust RDS's certificate authority, so a
# connection with sslmode=verify-full fails without this. The alternative --
# sslmode=require -- encrypts the connection but verifies nothing, which for the
# process that reads and writes every player balance is not a trade worth making.
#
# Pinned to an exact version rather than :latest. PostgREST reads the database
# schema at boot and its behaviour is sensitive to minor version changes; an
# unpinned image means the API can change shape on a restart nobody initiated.
#
# BUILD CONTEXT IS THE REPOSITORY ROOT, so the CA bundle is shared rather than
# duplicated per service. Build with:
#   docker build -f services/postgrest/Dockerfile .

FROM postgrest/postgrest:v12.2.3

# COPY from the repo, not ADD from a URL.
#
# `ADD <url>` silently produced no file in this base image (it works in
# node:22-alpine, so the behaviour is base-image specific), and PostgREST then
# crash-looped with 'root certificate file does not exist'. Copying a committed
# file is hermetic, needs no network at build time, and is verifiable locally.
COPY docker/rds-global-bundle.pem /opt/rds-global-bundle.pem

EXPOSE 3000
