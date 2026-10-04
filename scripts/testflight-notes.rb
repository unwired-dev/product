require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'

# App Store Connect betaBuildLocalizations are the TestFlight "What to Test" notes.
# https://developer.apple.com/documentation/appstoreconnectapi/beta-build-localizations
class TestFlightNotes
  def initialize(host, version, number, commit)
    @host, @version, @number, @commit = host, version, number, commit
    raise 'Invalid notes platform' unless %w[ios macos].include?(host)
    raise 'Invalid source commit' unless commit.match?(/\A[0-9a-f]{40}\z/)
    @key = OpenSSL::PKey.read(File.binread(ENV.fetch('ASC_KEY_PATH')))
    raise 'Expected a P-256 signing key' unless @key.is_a?(OpenSSL::PKey::EC) && @key.group.curve_name == 'prime256v1'
  end

  def token
    encode = ->(value) { Base64.urlsafe_encode64(value, padding: false) }
    now = Time.now.to_i
    header = { alg: 'ES256', kid: ENV.fetch('ASC_KEY_ID'), typ: 'JWT' }
    payload = { iss: ENV.fetch('ASC_ISSUER_ID'), iat: now, exp: now + 300, aud: 'appstoreconnect-v1' }
    unsigned = [header, payload].map { |value| encode.call(JSON.generate(value)) }.join('.')
    signature = OpenSSL::ASN1.decode(@key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(unsigned)))
    raw = signature.value.map { |integer| integer.value.to_i.to_s(16).rjust(64, '0') }.join
    "#{unsigned}.#{encode.call([raw].pack('H*'))}"
  end

  def request(method, path, query = {}, body = nil)
    uri = URI("https://api.appstoreconnect.apple.com/v1/#{path}")
    uri.query = URI.encode_www_form(query) unless query.empty?
    message = Net::HTTP.const_get(method).new(uri)
    message['Authorization'] = "Bearer #{token}"
    if body
      message['Content-Type'] = 'application/json'
      message.body = JSON.generate(body)
    end
    # Reads are idempotent: repeat a transient failure instead of failing after a completed upload.
    attempts = method == 'Get' ? 3 : 1
    response = nil
    attempts.times do |attempt|
      begin
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 30) do |http|
          http.request(message)
        end
        break unless response.code == '429' || response.code.start_with?('5')
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, SocketError
        raise 'App Store Connect notes request failed (network)' if attempt == attempts - 1
      end
      sleep 5 * (attempt + 1) unless attempt == attempts - 1
    end
    # Never include response bodies or the signed authorization token in errors.
    raise "App Store Connect notes request failed (HTTP #{response.code})" unless response.is_a?(Net::HTTPSuccess)
    return nil if response.code == '204'
    JSON.parse(response.body).fetch('data')
  end

  def upload
    apps = request('Get', 'apps', { 'filter[bundleId]' => 'dev.unwired.mail', 'limit' => '2' })
    raise 'Expected exactly one App Store Connect app' unless apps.is_a?(Array) && apps.length == 1
    build = nil
    40.times do |attempt|
      builds = request('Get', 'builds', {
        'filter[app]' => apps.first.fetch('id'), 'filter[version]' => @number,
        'filter[preReleaseVersion.version]' => @version,
        'filter[preReleaseVersion.platform]' => @host == 'ios' ? 'IOS' : 'MAC_OS', 'limit' => '2'
      })
      raise 'Ambiguous App Store Connect build' unless builds.is_a?(Array) && builds.length <= 1
      candidate = builds.first
      if candidate
        state = candidate.fetch('attributes').fetch('processingState')
        raise 'App Store Connect rejected the uploaded build' if %w[FAILED INVALID].include?(state)
        if state == 'VALID'
          build = candidate
          break
        end
        raise 'Unexpected build processing state' unless state == 'PROCESSING'
      end
      sleep 30 unless attempt == 39
    end
    raise 'Build processing timed out; TestFlight notes are incomplete' unless build
    localizations = request('Get', "builds/#{build.fetch('id')}/betaBuildLocalizations", { 'limit' => '200' })
    raise 'Invalid TestFlight localizations response' unless localizations.is_a?(Array)
    english = localizations.find { |item| item.fetch('attributes').fetch('locale') == 'en-US' }
    notes = "Source commit: #{@commit}\n#{@host} #{@version} (#{@number})"
    if english
      request('Patch', "betaBuildLocalizations/#{english.fetch('id')}", {}, {
        data: { type: 'betaBuildLocalizations', id: english.fetch('id'), attributes: { whatsNew: notes } }
      })
    else
      request('Post', 'betaBuildLocalizations', {}, {
        data: { type: 'betaBuildLocalizations', attributes: { locale: 'en-US', whatsNew: notes },
          relationships: { build: { data: { type: 'builds', id: build.fetch('id') } } } }
      })
    end
    puts "Updated TestFlight notes for #{@host}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    TestFlightNotes.new(*ARGV).upload
  rescue StandardError
    warn 'TestFlight notes failed; inspect App Store Connect processing and API access, then rerun the notes helper.'
    exit 1
  end
end
