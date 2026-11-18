# Postfix delivers example.test to Dovecot over LMTP and authenticates through Dovecot.
set -eu
printf '%s\n' \
  'alex@example.test:{PLAIN}synthetic-password' \
  'sam@example.test:{PLAIN}synthetic-password' > /etc/dovecot/users
postconf -e \
  'myhostname = localhost' \
  'mydestination =' \
  'inet_interfaces = all' \
  'inet_protocols = ipv4' \
  'maillog_file = /dev/stdout' \
  'virtual_mailbox_domains = example.test' \
  'virtual_transport = lmtp:unix:private/dovecot-lmtp' \
  'default_transport = error:only example.test is delivered' \
  'relay_transport = error:only example.test is delivered' \
  'smtpd_tls_cert_file = /certs/server.pem' \
  'smtpd_tls_key_file = /certs/server.key' \
  'smtpd_tls_mandatory_protocols = >=TLSv1.2' \
  'smtpd_tls_protocols = >=TLSv1.2' \
  'smtpd_sasl_type = dovecot' \
  'smtpd_sasl_path = private/auth' \
  'smtpd_relay_restrictions = permit_sasl_authenticated, reject'
# 465 is implicit TLS and 587 requires STARTTLS before AUTH; 2525 offers AUTH without any TLS,
# the misconfiguration the client must refuse.
postconf -M \
  'submissions/inet=submissions inet n - y - - smtpd' \
  'submission/inet=submission inet n - y - - smtpd' \
  '2525/inet=2525 inet n - y - - smtpd'
postconf -P \
  'submissions/inet/syslog_name=postfix/submissions' \
  'submissions/inet/smtpd_tls_wrappermode=yes' \
  'submissions/inet/smtpd_sasl_auth_enable=yes' \
  'submission/inet/syslog_name=postfix/submission' \
  'submission/inet/smtpd_tls_security_level=encrypt' \
  'submission/inet/smtpd_tls_auth_only=yes' \
  'submission/inet/smtpd_sasl_auth_enable=yes' \
  '2525/inet/syslog_name=postfix/plaintext' \
  '2525/inet/smtpd_tls_security_level=none' \
  '2525/inet/smtpd_sasl_auth_enable=yes'
