#!/bin/zsh
# Runs the iOS integration suite against the controlled standards server: Dovecot and Postfix in a
# local container with synthetic mailboxes only. Its certificate authority is made for this run and
# trusted only by the run's disposable simulator; a second container presents an untrusted
# self-signed certificate. Needs a running Docker engine.
set -euo pipefail
here=${0:A:h}
mkdir -p "${here:h:h:h}/artifacts/private-inbox"
run=$(mktemp -d "${here:h:h:h}/artifacts/private-inbox/standards.XXXXXX")
trusted='' untrusted=''
cleanup() {
  for container in "$trusted" "$untrusted"; do
    [[ -n "$container" ]] && docker rm -f "$container" >/dev/null 2>&1 || true
  done
  rm -f "$run/ca.key" "$run/trusted/server.key" "$run/untrusted/server.key" "$run/server.csr"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$run/trusted" "$run/untrusted"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Synthetic standards server CA' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout "$run/ca.key" -out "$run/ca.pem" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' \
  -keyout "$run/trusted/server.key" -out "$run/server.csr" 2>/dev/null
openssl x509 -req -days 1 -in "$run/server.csr" -CA "$run/ca.pem" -CAkey "$run/ca.key" \
  -extfile =(print 'subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE') \
  -out "$run/trusted/server.pem" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost' -addext 'extendedKeyUsage=serverAuth' \
  -keyout "$run/untrusted/server.key" -out "$run/untrusted/server.pem" 2>/dev/null

docker build -q -t unwired-standards-server "$here/standards-server" >/dev/null
start() {
  docker run -d --rm -v "$run/$1:/certs:ro" ${${@:2}/#/--publish=127.0.0.1::} unwired-standards-server
}
trusted=$(start trusted 993 143 465 587 2525)
untrusted=$(start untrusted 993 465)
for container in "$trusted" "$untrusted"; do
  for ready in {1..100}; do
    started=$(docker logs "$container" 2>&1)
    [[ "$started" == *'starting up for imap'* && "$started" == *'daemon started'* ]] && break
    (( ready < 100 )) || { docker logs "$container" >&2; exit 1; }
    sleep 0.1
  done
done
mapped() { docker port "$1" "$2/tcp" | head -1 | cut -d: -f2; }
export UNWIRED_STANDARDS_SERVER_PORTS=${(j:,:)$(
  for container service in $trusted 993 $trusted 143 $trusted 465 $trusted 587 $trusted 2525 \
    $untrusted 993 $untrusted 465; do mapped $container $service; done)}
export UNWIRED_STANDARDS_CA="$run/ca.pem"

result=0
zsh "$here/test.zsh" ios || result=$?
docker logs "$trusted" > "$run/trusted.log" 2>&1
docker logs "$untrusted" > "$run/untrusted.log" 2>&1
(( result == 0 )) || exit $result
# The suite logged in on 993, 465 and 587, and sent no credentials over plaintext or to the
# untrusted server.
fail() { print -u2 "Standards server: $1"; exit 1; }
matching() { grep -E "$2" "$run/$1.log" || true; }
unauthenticated() { [[ -n "$1" && -z $(print -r -- "$1" | grep -v '(no auth attempts' || true) ]]; }
[[ -n $(matching trusted 'Login: .*lport=993,') ]] || fail 'no IMAP login on 993'
unauthenticated "$(matching trusted 'imap-login: .*lport=143,')" || fail 'credentials sent to IMAP 143'
for service in submissions submission; do
  [[ -n $(matching trusted "postfix/$service/smtpd.*sasl_method=") ]] || fail "no SMTP login on $service"
done
[[ -n $(matching trusted 'postfix/plaintext/smtpd.*disconnect') &&
  -z $(matching trusted 'postfix/plaintext/smtpd.*(auth=|sasl_)') ]] ||
  fail 'credentials sent to SMTP without TLS'
unauthenticated "$(matching untrusted 'imap-login:')" &&
  [[ -n $(matching untrusted 'postfix/submissions/smtpd.*disconnect') &&
    -z $(matching untrusted 'auth=|sasl_') ]] || fail 'credentials sent to the untrusted server'
print "Standards server evidence: $run"
