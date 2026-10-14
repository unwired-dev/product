require 'fileutils'
require 'tmpdir'
require_relative 'testflight-certificates'

# Exercise real CSR generation and certificate matching, replacing only Apple HTTP.
def assert(condition, message)
  raise message unless condition
end

def certificate_record(key, expires, team = 'SYNTHETIC1')
  certificate = OpenSSL::X509::Certificate.new
  certificate.version = 2
  certificate.serial = expires.to_i
  certificate.subject = OpenSSL::X509::Name.new([['CN', 'Synthetic development'], ['OU', team]])
  certificate.issuer = certificate.subject
  certificate.public_key = key.public_key
  certificate.not_before = Time.utc(2025)
  certificate.not_after = expires
  certificate.sign(key, OpenSSL::Digest::SHA256.new)
  { 'id' => expires.to_i.to_s, 'attributes' => { 'certificateType' => 'DEVELOPMENT',
    'certificateContent' => Base64.strict_encode64(certificate.to_der) } }
end

scratchpad = File.expand_path('../scratchpad', __dir__)
FileUtils.mkdir_p(scratchpad)
Dir.mktmpdir('testflight-certificates-', scratchpad) do |directory|
  ENV['ASC_KEY_PATH'] = File.join(directory, 'synthetic.p8')
  ENV['ASC_KEY_ID'] = 'SYNTHETIC1'
  ENV['ASC_ISSUER_ID'] = 'synthetic-issuer'
  ENV['APPLE_DEVELOPMENT_TEAM'] = 'SYNTHETIC1'
  ENV['TESTFLIGHT_SIGNING_KEY_PATH'] = File.join(directory, 'signing.pem')
  File.write(ENV.fetch('ASC_KEY_PATH'), OpenSSL::PKey::EC.generate('prime256v1').to_pem)
  key = OpenSSL::PKey::RSA.new(2048)
  File.write(ENV.fetch('TESTFLIGHT_SIGNING_KEY_PATH'), key.to_pem)
  other_key = OpenSSL::PKey::RSA.new(2048)
  now = Time.utc(2026, 10, 14)
  unrelated = certificate_record(other_key, now + 365 * 86400)
  records = [unrelated]
  requests = []
  failure = false
  next_page = nil
  invalid_issued = false
  quota_exhausted = false
  transport = Object.new
  transport.define_singleton_method(:request) do |message|
    requests << message
    assert(message['Authorization'].start_with?('Bearer '), 'Missing API token')
    uri = URI(message.path)
    if failure
      response = Net::HTTPForbidden.new('1.1', '403', 'Forbidden')
      response.define_singleton_method(:body) { '{"errors":[{"detail":"NEVER_LOG_RESPONSE_BODY"}]}' }
      next response
    end
    assert(uri.path == '/v1/certificates', 'Unexpected certificate endpoint')
    if message.method == 'GET'
      query = URI.decode_www_form(uri.query || '').to_h
      assert(query['filter[certificateType]'] == 'DEVELOPMENT' && query['limit'] == '200', 'Missing development filter')
      response = Net::HTTPOK.new('1.1', '200', 'OK')
      response.define_singleton_method(:body) { JSON.generate({ data: records, links: { next: next_page } }) }
    else
      assert(message.method == 'POST', 'No existing certificates may be revoked')
      attributes = JSON.parse(message.body).fetch('data').fetch('attributes')
      assert(attributes.fetch('certificateType') == 'DEVELOPMENT', 'Wrong certificate type requested')
      csr = OpenSSL::X509::Request.new(attributes.fetch('csrContent'))
      assert(csr.verify(key.public_key) && csr.public_key.to_der == key.public_key.to_der, 'CSR must use persisted private key')
      if quota_exhausted
        response = Net::HTTPConflict.new('1.1', '409', 'Conflict')
        response.define_singleton_method(:body) { '{"errors":[{"detail":"NEVER_LOG_QUOTA_RESPONSE"}]}' }
        next response
      end
      record = certificate_record(invalid_issued ? other_key : key, now + 365 * 86400)
      records << record
      response = Net::HTTPCreated.new('1.1', '201', 'Created')
      response.define_singleton_method(:body) { JSON.generate({ data: record }) }
    end
    response
  end
  Net::HTTP.define_singleton_method(:start) do |host, port, **options, &block|
    assert(host == 'api.appstoreconnect.apple.com' && port == 443 && options[:use_ssl], 'Request escaped protected HTTPS origin')
    block.call(transport)
  end
  prepare = -> { DevelopmentCertificate.new.prepare(-> { now }) }
  first = prepare.call
  second = prepare.call
  assert(first.to_der == second.to_der && first.check_private_key(key), 'Repeated runs must reuse the same identity')
  assert(requests.count { |r| r.method == 'POST' } == 1, 'Valid identity was recreated')
  # Run the CLI entry point with the same real key and substituted Apple transport.
  output = File.join(directory, 'certificate.hex')
  child = fork do
    $stdout.reopen(output, 'w')
    $VERBOSE = nil
    Time.define_singleton_method(:now) { now }
    $0 = File.expand_path('testflight-certificates.rb', __dir__)
    load $0
  end
  Process.wait(child)
  assert($?.success?, 'Certificate CLI failed')
  encoded = File.read(output).strip
  assert(encoded.match?(/\A(?:[0-9a-f]{2})+\z/) && [encoded].pack('H*') == first.to_der, 'Certificate output must use lossless hex DER')
  key.to_pem.lines.map(&:strip).reject { |line| line.start_with?('-') }.each do |line|
    assert(!encoded.include?(line), 'Public certificate output matches a private PEM secret mask')
  end
  [now - 1, now + DevelopmentCertificate::BUILD_WINDOW].each do |expiration|
    records = [unrelated, certificate_record(key, expiration)]
    renewed = prepare.call
    assert(renewed.not_after > now + DevelopmentCertificate::BUILD_WINDOW, 'Expired or expiring identity was reused')
    assert(records.first == unrelated && records.length == 3, 'Renewal changed an existing certificate')
  end
  records = [unrelated] # A manually revoked certificate disappears from Apple.
  assert(prepare.call.check_private_key(key), 'Revoked identity was not replaced')
  [[:incomplete, 'App Store Connect response is incomplete'], [:http, 'App Store Connect notes request failed (HTTP 403)'],
   [:quota, 'App Store Connect notes request failed (HTTP 409)'],
   [:wrong_team, 'Signing certificate belongs to another team'], [:wrong_key, 'Invalid issued signing certificate']].each do |scenario, expected|
    next_page = scenario == :incomplete ? 'https://api.appstoreconnect.apple.com/v1/certificates?cursor=next' : nil
    failure = scenario == :http
    invalid_issued = scenario == :wrong_key
    quota_exhausted = scenario == :quota
    records = scenario == :wrong_team ? [certificate_record(key, now + 86400, 'OTHERTEAM1')] : [unrelated]
    before = requests.length
    begin
      prepare.call
      raise 'Invalid signing state unexpectedly accepted'
    rescue RuntimeError => error
      assert(error.message == expected, 'Failure was not classified safely')
    end
    if scenario == :quota
      assert(records == [unrelated] && requests[before..].map(&:method) == %w[GET POST], 'Quota refusal changed certificates or retried issuance')
    elsif scenario != :wrong_key
      assert(requests[before..].all? { |r| r.method == 'GET' }, 'Failed listing created a certificate')
    end
  end
  puts 'Passed TestFlight certificate contracts: creation, reuse, expiry, revocation, key and team matching, API failures'
end
