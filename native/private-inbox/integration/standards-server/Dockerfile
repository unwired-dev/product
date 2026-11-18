# The controlled standards server: Dovecot and Postfix with synthetic mailboxes only.
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    dovecot-imapd dovecot-lmtpd postfix \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --system --uid 5000 --home-dir /var/mail/vhosts vmail \
  && mkdir -p /var/mail/vhosts && chown vmail:vmail /var/mail/vhosts
COPY dovecot.conf /etc/dovecot/dovecot.conf
COPY postfix.sh /usr/local/bin/postfix.sh
RUN sh /usr/local/bin/postfix.sh
# The run mounts its certificate and key at /certs.
CMD ["sh", "-c", "dovecot -F & exec postfix start-fg"]
