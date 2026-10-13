require 'fileutils'
require 'tmpdir'
require_relative 'testflight-certificates'

# No network is opened: only API-created development certificates older than two hours are revoked.
def assert(condition, message)
  raise message unless condition
end

scratchpad = File.expand_path('../scratchpad', __dir__)
FileUtils.mkdir_p(scratchpad)
Dir.mktmpdir('testflight-certificates-', scratchpad) do |directory|
  ENV['ASC_KEY_PATH'] = File.join(directory, 'synthetic.p8')
  ENV['ASC_KEY_ID'] = 'SYNTHETIC1'
  ENV['ASC_ISSUER_ID'] = 'synthetic-issuer'
  File.write(ENV.fetch('ASC_KEY_PATH'), OpenSSL::PKey::EC.generate('prime256v1').to_pem)
  now = Time.utc(2026, 10, 13, 12, 0, 0)
  requests = []
  failure = false
  next_page = nil
  transport = Object.new
  transport.define_singleton_method(:request) do |message|
    requests << message
    assert(message['Authorization'].start_with?('Bearer '), 'Missing API token')
    uri = URI(message.path)
    query = URI.decode_www_form(uri.query || '').to_h
    if failure
      response = Net::HTTPForbidden.new('1.1', '403', 'Forbidden')
      response.define_singleton_method(:body) { JSON.generate({ errors: [{ detail: 'NEVER_LOG_RESPONSE_BODY' }] }) }
      next response
    end
    if message.method == 'GET'
      assert(uri.path == '/v1/certificates' && query['filter[certificateType]'] == 'DEVELOPMENT' && query['limit'] == '200',
        'Expected a development certificate listing')
      response = Net::HTTPOK.new('1.1', '200', 'OK')
      data = [
        { 'id' => 'runner-1', 'attributes' => { 'certificateType' => 'DEVELOPMENT', 'displayName' => 'Created via API', 'expirationDate' => '2027-10-12T12:00:00.000+00:00' } },
        { 'id' => 'person', 'attributes' => { 'certificateType' => 'DEVELOPMENT', 'displayName' => 'Synthetic Developer', 'expirationDate' => '2027-07-15T12:00:00.000Z' } },
        { 'id' => 'local', 'attributes' => { 'certificateType' => 'DEVELOPMENT', 'displayName' => 'Created via API', 'expirationDate' => '2027-10-13T11:30:00.000Z' } },
        { 'id' => 'runner-2', 'attributes' => { 'certificateType' => 'DEVELOPMENT', 'displayName' => 'Created via API', 'expirationDate' => '2027-10-13T09:00:00.000Z' } },
        { 'id' => 'boundary', 'attributes' => { 'certificateType' => 'DEVELOPMENT', 'displayName' => 'Created via API', 'expirationDate' => '2027-10-13T10:00:00.000+00:00' } },
        { 'id' => 'runner-fraction', 'attributes' => { 'certificateType' => 'DEVELOPMENT', 'displayName' => 'Created via API', 'expirationDate' => '2027-10-13T11:59:59.999+02:00' } },
        { 'id' => 'local-fraction', 'attributes' => { 'certificateType' => 'DEVELOPMENT', 'displayName' => 'Created via API', 'expirationDate' => '2027-10-13T05:00:00.001-05:00' } }
      ]
      response.define_singleton_method(:body) { JSON.generate({ data: data, links: { next: next_page } }) }
      next response
    end
    assert(message.method == 'DELETE' && uri.path.start_with?('/v1/certificates/runner-'), "Unexpected request #{message.method} #{uri.path}")
    Net::HTTPNoContent.new('1.1', '204', 'No Content')
  end
  Net::HTTP.define_singleton_method(:start) do |host, port, **options, &block|
    assert(host == 'api.appstoreconnect.apple.com' && port == 443 && options[:use_ssl], 'Request escaped protected HTTPS origin')
    block.call(transport)
  end

  StaleDevelopmentCertificates.new.revoke(now)
  deleted = requests.select { |request| request.method == 'DELETE' }.map { |request| URI(request.path).path }
  assert(deleted == %w[/v1/certificates/runner-1 /v1/certificates/runner-2 /v1/certificates/runner-fraction], 'Expected exactly the API-created certificates older than two hours to be revoked, including fractional seconds and timezone offsets')
  next_page = 'https://api.appstoreconnect.apple.com/v1/certificates?cursor=next'
  before = requests.length
  begin
    StaleDevelopmentCertificates.new.revoke(now)
    raise 'Incomplete certificate listing unexpectedly accepted'
  rescue RuntimeError => error
    assert(error.message == 'App Store Connect response is incomplete', 'Incomplete listing did not fail closed')
  end
  assert(requests[before..].none? { |request| request.method == 'DELETE' }, 'Certificates revoked before checking listing completeness')
  next_page = nil
  failure = true
  begin
    StaleDevelopmentCertificates.new.revoke(now)
    raise 'HTTP failure unexpectedly accepted'
  rescue RuntimeError => error
    assert(error.message == 'App Store Connect notes request failed (HTTP 403)', 'Sensitive response included in error')
  end
  puts 'Passed TestFlight certificate contracts: API-created development certificates older than two hours only, incomplete listing, HTTP failure'
end
