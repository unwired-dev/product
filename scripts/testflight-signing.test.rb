require 'fileutils'
require 'json'
require 'open3'
require 'openssl'
require 'tmpdir'

# Real PKCS#12 creation and wrapper execution; only macOS security is substituted.
root = File.expand_path('..', __dir__)
FileUtils.mkdir_p("#{root}/scratchpad")
Dir.mktmpdir("testflight-signing with spaces-", "#{root}/scratchpad") do |directory|
  key = OpenSSL::PKey::RSA.new(2048)
  certificate = OpenSSL::X509::Certificate.new
  certificate.serial = 1
  certificate.subject = OpenSSL::X509::Name.new([['CN', 'Synthetic signing']])
  certificate.issuer = certificate.subject
  certificate.public_key = key.public_key
  certificate.not_before = Time.now - 60
  certificate.not_after = Time.now + 86400
  certificate.sign(key, OpenSSL::Digest::SHA256.new)
  bin = "#{directory}/bin"
  FileUtils.mkdir_p(bin)
  File.write("#{bin}/security", <<~'STUB')
    #!/usr/bin/env ruby
    require 'json'
    require 'openssl'
    require 'shellwords'
    raise 'Secret in security environment' if ENV['TESTFLIGHT_SIGNING_KEY']
    if ARGV == ['-i']
      ARGV.replace(Shellwords.split(STDIN.read))
    elsif ARGV.any? { |argument| %w[-p -P -k].include?(argument) } && ARGV.first != 'find-identity'
      raise 'Password in process arguments'
    end
    operation = ARGV.first
    File.open(ENV.fetch('CALLS'), 'a') { |f| f.puts(operation == 'list-keychains' ? ARGV.to_json : [operation].to_json) }
    case operation
    when 'list-keychains'
      puts '    "/original/login with spaces.keychain-db"' unless ARGV.include?('-s')
      exit 1 if ARGV.include?('-s') && ENV['SCENARIO'] == 'restore-failure' && ARGV.last.start_with?('/original/')
    when 'import'
      path = ARGV.fetch(1)
      raise 'Readable private material' unless File.stat(path).mode & 0o077 == 0
      password = ARGV.fetch(ARGV.index('-P') + 1)
      identity = OpenSSL::PKCS12.new(File.binread(path), password)
      raise 'Invalid signing identity' unless identity.certificate.check_private_key(identity.key)
      exit 1 if ENV['SCENARIO'] == 'import-failure'
    when 'create-keychain', 'unlock-keychain', 'set-key-partition-list'
      exit 1 if ENV['SCENARIO'] == "#{operation}-failure"
    when 'find-identity'
      keychain = ARGV.last
      fingerprint = File.read("#{File.dirname(keychain)}/fingerprint")
      puts "1) #{fingerprint} Synthetic signing" unless ENV['SCENARIO'] == 'missing-identity'
    when 'delete-keychain'
      exit 1 if ENV['SCENARIO'] == 'delete-failure'
    end
  STUB
  File.chmod(0o755, "#{bin}/security")
  File.write("#{directory}/upload.rb", <<~'CHILD')
    raise 'Signing key leaked to build' if ENV['TESTFLIGHT_SIGNING_KEY'] || ENV['TESTFLIGHT_CERTIFICATE']
    private_files = Dir.glob("#{ENV.fetch('RUNNER_TEMP')}/testflight-signing.*/*").grep(/key\.pem|identity\.p12|password$/)
    raise 'Private files retained during build' unless private_files.empty?
    File.write("#{ENV.fetch('RUNNER_TEMP')}/uploaded", 'yes')
    case ENV.fetch('SCENARIO')
    when 'failure' then exit 42
    when 'SIGINT', 'SIGTERM' then Process.kill(ENV.fetch('SCENARIO'), Process.ppid)
    end
  CHILD
  { 'success' => 0, 'failure' => 42, 'SIGINT' => 130, 'SIGTERM' => 143,
    'create-keychain-failure' => 1, 'unlock-keychain-failure' => 1, 'import-failure' => 1,
    'set-key-partition-list-failure' => 1, 'missing-identity' => 1, 'restore-failure' => 1,
    'delete-failure' => 1, 'malformed' => 1, 'expired' => 1 }.each do |scenario, expected|
    run = "#{directory}/#{scenario}"
    FileUtils.mkdir_p(run)
    certificate.not_after = scenario == 'expired' ? Time.now - 1 : Time.now + 86400
    certificate.sign(key, OpenSSL::Digest::SHA256.new)
    env = { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}", '__ETC_ZSHENV_SOURCED' => '1', 'HOME' => run,
      'RUNNER_TEMP' => run, 'CALLS' => "#{run}/calls", 'SCENARIO' => scenario,
      'TESTFLIGHT_SIGNING_KEY' => key.to_pem,
      'TESTFLIGHT_CERTIFICATE' => scenario == 'malformed' ? 'INVALID_CERTIFICATE_SENTINEL' : certificate.to_der.unpack1('H*') }
    output, status = Open3.capture2e(env, '/bin/zsh', "#{root}/scripts/testflight-signing.zsh", 'ruby', "#{directory}/upload.rb", unsetenv_others: true)
    raise "#{scenario}: wrong exit #{status.exitstatus}: #{output}" unless status.exitstatus == expected
    raise 'Secret reached diagnostics' if output.include?('PRIVATE KEY') || output.include?('INVALID_CERTIFICATE_SENTINEL')
    raise "#{scenario}: temporary signing material retained" unless Dir.glob("#{run}/testflight-signing.*").empty?
    if %w[malformed expired].include?(scenario)
      raise 'Invalid certificate reached keychain' if File.exist?("#{run}/calls")
    else
      calls = File.readlines("#{run}/calls").map { |line| JSON.parse(line) }
      raise 'Original keychain search list not restored' unless calls[-2] == ['list-keychains', '-d', 'user', '-s', '/original/login with spaces.keychain-db']
      raise 'Temporary keychain not deleted' unless calls.last == ['delete-keychain']
      setup_failed = %w[create-keychain-failure unlock-keychain-failure import-failure set-key-partition-list-failure missing-identity].include?(scenario)
      raise 'Signing setup failure reached upload' if setup_failed && File.exist?("#{run}/uploaded")
    end
  end
  puts 'Passed TestFlight keychain contracts: import, isolation, failure, signals and cleanup'
end
