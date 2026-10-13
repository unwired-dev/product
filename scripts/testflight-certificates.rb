require_relative 'testflight-notes'

require 'time'

# API-created development certificates accumulate on ephemeral runners;
# revoking matching certificates before the next upload keeps the team under Apple's limit.
# https://developer.apple.com/documentation/appstoreconnectapi/certificates
class StaleDevelopmentCertificates < AppStoreConnect
  # A local upload outside the workflow queue keeps the certificate it just created:
  # the API reports no creation date, but development certificates expire one year
  # after creation, and an upload finishes well within two hours.
  VALIDITY = 365 * 24 * 60 * 60
  GRACE = 2 * 60 * 60

  def revoke(now = Time.now)
    certificates = request('Get', 'certificates', { 'filter[certificateType]' => 'DEVELOPMENT', 'limit' => '200' }, require_complete: true)
    raise 'Invalid certificates response' unless certificates.is_a?(Array)
    stale = certificates.select do |certificate|
      attributes = certificate.fetch('attributes')
      attributes.fetch('displayName') == 'Created via API' &&
        Time.iso8601(attributes.fetch('expirationDate')) - VALIDITY < now - GRACE
    end
    stale.each { |certificate| request('Delete', "certificates/#{certificate.fetch('id')}") }
    puts "Revoked #{stale.length} API-created development certificates older than two hours"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    StaleDevelopmentCertificates.new.revoke
  rescue StandardError
    warn 'Revoking development certificates failed; inspect App Store Connect API access, then rerun.'
    exit 1
  end
end
