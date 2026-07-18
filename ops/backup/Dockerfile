FROM postgres:16-alpine

RUN apk add --no-cache openssl

COPY backup check-backup verify-backup backup-loop /opt/hydra-backup/
RUN mkdir -p /backups \
  && chown postgres:postgres /backups \
  && chmod 0555 \
  /opt/hydra-backup/backup \
  /opt/hydra-backup/check-backup \
  /opt/hydra-backup/verify-backup \
  /opt/hydra-backup/backup-loop

USER postgres
ENTRYPOINT ["/opt/hydra-backup/backup-loop"]
