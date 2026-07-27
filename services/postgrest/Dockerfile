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

FROM postgrest/postgrest:v12.2.3

# Published Amazon RDS trust store. `ADD` works regardless of what shell (if
# any) the base image provides.
ADD --chmod=444 https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
    /etc/ssl/certs/rds-global-bundle.pem

# PostgREST connects via libpq, which reads these.
ENV PGSSLROOTCERT=/etc/ssl/certs/rds-global-bundle.pem

EXPOSE 3000
