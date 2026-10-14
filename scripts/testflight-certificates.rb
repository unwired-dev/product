require_relative 'testflight-notes'

class DevelopmentCertificate < AppStoreConnect
  # Both upload jobs must finish before the selected certificate expires.
  BUILD_WINDOW = 2 * 60 * 60

  def prepare(clock = -> { Time.now })
    now = clock.call
    key = OpenSSL::PKey.read(File.binread(ENV.fetch('TESTFLIGHT_SIGNING_KEY_PATH')))
    raise 'Expected an RSA private key' unless key.is_a?(OpenSSL::PKey::RSA) && key.private? && key.n.num_bits >= 2048
    team = ENV.fetch('APPLE_DEVELOPMENT_TEAM')
    raise 'Invalid development team' unless team.match?(/\A[A-Z0-9]{10}\z/)
    records = request('Get', 'certificates', { 'filter[certificateType]' => 'DEVELOPMENT', 'limit' => '200' }, require_complete: true)
    raise 'Invalid certificates response' unless records.is_a?(Array)
    matching = records.filter_map do |record|
      certificate = decode(record)
      next unless certificate.check_private_key(key)
      raise 'Signing certificate belongs to another team' unless certificate.subject.to_a.any? { |name, value, _| name == 'OU' && value == team }
      certificate
    end
    certificate = matching.select { |item| item.not_before <= now && item.not_after > now + BUILD_WINDOW }.max_by(&:not_after)
    return certificate unless certificate.nil?

    csr = OpenSSL::X509::Request.new
    csr.version = 0
    csr.subject = OpenSSL::X509::Name.new([['CN', 'Unwired TestFlight']])
    csr.public_key = key.public_key
    csr.sign(key, OpenSSL::Digest::SHA256.new)
    certificate = decode(request('Post', 'certificates', {}, {
      data: { type: 'certificates', attributes: { certificateType: 'DEVELOPMENT', csrContent: csr.to_pem } }
    }))
    now = clock.call
    unless certificate.check_private_key(key) && certificate.not_before <= now && certificate.not_after > now + BUILD_WINDOW &&
           certificate.subject.to_a.any? { |name, value, _| name == 'OU' && value == team }
      raise 'Invalid issued signing certificate'
    end
    certificate
  end

  def decode(record)
    attributes = record.fetch('attributes')
    raise 'Expected a development certificate' unless attributes.fetch('certificateType') == 'DEVELOPMENT'
    OpenSSL::X509::Certificate.new(Base64.strict_decode64(attributes.fetch('certificateContent')))
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    # Hex avoids matching the RSA modulus in GitHub's line-by-line PEM secret masks.
    puts DevelopmentCertificate.new.prepare.to_der.unpack1('H*')
  rescue StandardError
    warn 'Preparing development signing failed; inspect the signing key, team and App Store Connect API access, then rerun.'
    exit 1
  end
end
