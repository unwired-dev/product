require 'fileutils'
require 'tmpdir'
require_relative 'testflight-notes'

# No network is opened: exercise real JWT signing and request serialization
# against a fake Net::HTTP transport and synthetic processing responses.
def assert(condition, message)
  raise message unless condition
end

# Git does not track the empty scratchpad directory.
scratchpad = File.expand_path('../scratchpad', __dir__)
FileUtils.mkdir_p(scratchpad)
Dir.mktmpdir('testflight-notes-', scratchpad) do |directory|
  key = OpenSSL::PKey::EC.generate('prime256v1')
  ENV['ASC_KEY_PATH'] = File.join(directory, 'synthetic.p8')
  ENV['ASC_KEY_ID'] = 'SYNTHETIC1'
  ENV['ASC_ISSUER_ID'] = 'synthetic-issuer'
  File.write(ENV.fetch('ASC_KEY_PATH'), key.to_pem)
  commit = 'a' * 40
  platform = 'IOS'
  states = []
  localizations = []
  requests = []
  failure = false
  transient = 0
  sleeps = 0
  TestFlightNotes.define_method(:sleep) { |_seconds| sleeps += 1 }
  transport = Object.new
  transport.define_singleton_method(:request) do |message|
    requests << message
    header, payload, signature = message['Authorization'].delete_prefix('Bearer ').split('.')
    decoded_header = JSON.parse(Base64.urlsafe_decode64(header))
    decoded_payload = JSON.parse(Base64.urlsafe_decode64(payload))
    assert(decoded_header['alg'] == 'ES256' && decoded_header['kid'] == 'SYNTHETIC1', 'Invalid JWT header')
    assert(decoded_payload['iss'] == 'synthetic-issuer' && decoded_payload['aud'] == 'appstoreconnect-v1', 'Invalid JWT audience')
    assert(decoded_payload['exp'] - decoded_payload['iat'] == 300, 'Invalid JWT expiration')
    raw = Base64.urlsafe_decode64(signature)
    assert(raw.bytesize == 64, 'Expected JOSE raw ES256 signature')
    integers = [raw[0, 32], raw[32, 32]].map { |part| OpenSSL::ASN1::Integer.new(OpenSSL::BN.new(part.unpack1('H*'), 16)) }
    der = OpenSSL::ASN1::Sequence.new(integers).to_der
    assert(key.dsa_verify_asn1(OpenSSL::Digest::SHA256.digest("#{header}.#{payload}"), der), 'Signature failed independent verification')
    response = failure ? Net::HTTPForbidden.new('1.1', '403', 'Forbidden') : Net::HTTPOK.new('1.1', '200', 'OK')
    if transient.positive?
      transient -= 1
      assert(message.method == 'GET', 'Write unexpectedly reached a transient failure')
      response = Net::HTTPServiceUnavailable.new('1.1', '503', 'Unavailable')
    end
    uri = URI(message.path)
    query = URI.decode_www_form(uri.query || '').to_h
    data = case uri.path
           when '/v1/apps'
             assert(query['filter[bundleId]'] == 'dev.unwired.mail', 'Wrong application lookup')
             [{ 'id' => 'app-id' }]
           when '/v1/builds'
             assert(query['filter[app]'] == 'app-id', 'Build not scoped to app')
             assert(query['filter[version]'] == '202610031234' && query['filter[preReleaseVersion.version]'] == '0.1.0', 'Wrong build/version lookup')
             assert(query['filter[preReleaseVersion.platform]'] == platform, 'Wrong platform lookup')
             state = states.length > 1 ? states.shift : states.first
             state ? [{ 'id' => 'build-id', 'attributes' => { 'processingState' => state } }] : []
           when '/v1/builds/build-id/betaBuildLocalizations'
             assert(query['limit'] == '200', 'Localization listing may paginate')
             localizations
           when '/v1/betaBuildLocalizations', '/v1/betaBuildLocalizations/english-id'
             body = JSON.parse(message.body).fetch('data')
             assert(body['type'] == 'betaBuildLocalizations' && body.fetch('attributes').fetch('whatsNew').include?(commit), 'Missing commit in TestFlight notes')
             if message.method == 'POST'
               assert(body.fetch('attributes').fetch('locale') == 'en-US', 'Wrong locale')
               assert(body.fetch('relationships').fetch('build').fetch('data') == { 'type' => 'builds', 'id' => 'build-id' }, 'Wrong localization build relationship')
             else
               assert(message.method == 'PATCH' && body['id'] == 'english-id', 'Invalid update')
             end
             { 'id' => 'english-id' }
           else raise "Unexpected stub request: #{uri.path}"
           end
    body = JSON.generate({ data: data, secret: 'NEVER_LOG_RESPONSE_BODY' })
    response.define_singleton_method(:body) { body }
    response
  end
  Net::HTTP.define_singleton_method(:start) do |host, port, **options, &block|
    assert(host == 'api.appstoreconnect.apple.com' && port == 443 && options[:use_ssl], 'Request escaped protected HTTPS origin')
    block.call(transport)
  end

  states = %w[PROCESSING VALID]
  TestFlightNotes.new('ios', '0.1.0', '202610031234', commit).upload
  assert(sleeps == 1 && requests.last.method == 'POST', 'Missing processing wait/create')
  platform = 'MAC_OS'
  states = ['VALID']
  localizations = [{ 'id' => 'english-id', 'attributes' => { 'locale' => 'en-US' } }]
  TestFlightNotes.new('macos', '0.1.0', '202610031234', commit).upload
  assert(requests.last.method == 'PATCH', 'Existing notes not updated idempotently')
  %w[FAILED INVALID].each do |state|
    states = [state]
    before = requests.length
    begin
      TestFlightNotes.new('macos', '0.1.0', '202610031234', commit).upload
      raise 'Rejected build unexpectedly accepted'
    rescue RuntimeError => error
      assert(error.message == 'App Store Connect rejected the uploaded build', 'Rejected build did not fail closed')
    end
    assert(requests[before..].none? { |request| %w[POST PATCH].include?(request.method) }, 'Notes written to invalid build')
  end
  states = []
  before = requests.length
  begin
    TestFlightNotes.new('macos', '0.1.0', '202610031234', commit).upload
    raise 'Missing build unexpectedly accepted'
  rescue RuntimeError => error
    assert(error.message.include?('timed out'), 'Processing timeout not reported')
  end
  assert(requests[before..].count { |request| URI(request.path).path == '/v1/builds' } == 40, 'Unbounded processing poll')
  # A transient read failure is repeated; a persistent one still fails closed.
  states = ['VALID']
  transient = 2
  TestFlightNotes.new('macos', '0.1.0', '202610031234', commit).upload
  assert(requests.last.method == 'PATCH', 'Transient read failure was not retried')
  transient = 3
  begin
    TestFlightNotes.new('macos', '0.1.0', '202610031234', commit).upload
    raise 'Persistent read failure unexpectedly accepted'
  rescue RuntimeError => error
    assert(error.message == 'App Store Connect notes request failed (HTTP 503)', 'Persistent read failure not reported')
  end
  transient = 0
  failure = true
  begin
    TestFlightNotes.new('macos', '0.1.0', '202610031234', commit).upload
    raise 'HTTP failure unexpectedly accepted'
  rescue RuntimeError => error
    assert(error.message == 'App Store Connect notes request failed (HTTP 403)', 'Sensitive response included in error')
  end
  puts 'Passed TestFlight notes contracts: JWT, create/update, platform/build scoping, processing rejection, timeout, read retries and HTTP failure'
end
