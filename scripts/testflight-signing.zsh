#!/bin/zsh
# Run the upload with a reusable identity in a temporary keychain.
set -eo pipefail
umask 077
directory=$(mktemp -d "${RUNNER_TEMP:?}/testflight-signing.XXXXXX")
keychain="$directory/signing.keychain-db"
original_keychains=()
created=0
cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if (( created )); then
    security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || result=1
    security delete-keychain "$keychain" >/dev/null 2>&1 || result=1
  fi
  rm -rf "$directory"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ -n "${TESTFLIGHT_SIGNING_KEY:-}" && -n "${TESTFLIGHT_CERTIFICATE:-}" && $# -gt 0 ]] || exit 2
print -r -- "$TESTFLIGHT_SIGNING_KEY" > "$directory/key.pem"
print -r -- "$TESTFLIGHT_CERTIFICATE" > "$directory/certificate.hex"
unset TESTFLIGHT_SIGNING_KEY TESTFLIGHT_CERTIFICATE
# The private key and PKCS#12 never reach project build phases or artifacts.
ruby -ropenssl -rsecurerandom - "$directory" <<'RUBY'
directory = ARGV.fetch(0)
begin
  key = OpenSSL::PKey.read(File.binread("#{directory}/key.pem"))
  encoded = File.read("#{directory}/certificate.hex").strip
  raise 'Invalid certificate encoding' unless encoded.match?(/\A(?:[0-9a-f]{2})+\z/)
  certificate = OpenSSL::X509::Certificate.new([encoded].pack('H*'))
  raise 'Invalid identity' unless certificate.check_private_key(key) && certificate.not_before <= Time.now && certificate.not_after > Time.now + 3600
  password = SecureRandom.hex(32)
  File.write("#{directory}/password", password)
  # macOS security import needs the legacy PKCS#12 algorithms.
  identity = OpenSSL::PKCS12.create(password, 'TestFlight', key, certificate, nil, 'PBE-SHA1-3DES', 'PBE-SHA1-3DES')
  File.binwrite("#{directory}/identity.p12", identity.to_der)
  File.write("#{directory}/fingerprint", OpenSSL::Digest::SHA1.hexdigest(certificate.to_der).upcase)
rescue StandardError
  warn 'Could not prepare the TestFlight signing identity'
  exit 1
end
RUBY
password=$(<"$directory/password")
original_list=$(security list-keychains -d user)
original_keychains=("${(@Q)${(z)original_list}}")
# One command per invocation preserves failures while keeping passwords out of argv.
created=1
security -i <<< "create-keychain -p $password ${(q)keychain}" >/dev/null 2>&1
security set-keychain-settings -lut 7200 "$keychain" >/dev/null 2>&1
security -i <<< "unlock-keychain -p $password ${(q)keychain}" >/dev/null 2>&1
security -i <<< "import ${(q)directory}/identity.p12 -k ${(q)keychain} -P $password -T /usr/bin/codesign -T /usr/bin/security" >/dev/null 2>&1
security -i <<< "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $password ${(q)keychain}" >/dev/null 2>&1
security list-keychains -d user -s "$keychain" >/dev/null 2>&1
fingerprint=$(<"$directory/fingerprint")
identities=$(security find-identity -v -p codesigning "$keychain" 2>/dev/null)
if [[ "$identities" != *" $fingerprint "* ]]; then
  print -u2 'The prepared TestFlight identity is not valid for code signing'
  exit 1
fi
rm -f "$directory/key.pem" "$directory/identity.p12" "$directory/password"
unset password
print -r -- "Prepared TestFlight identity: $fingerprint"
"$@"
