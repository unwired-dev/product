require 'fileutils'
require 'json'
require 'open3'
require 'openssl'
require 'tmpdir'

# Real key/certificate preparation and wrapper execution; native mode uses macOS security.
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
  if ARGV == ['--native']
    raise 'Native signing check requires macOS' unless RUBY_PLATFORM.include?('darwin')
    original, original_status = Open3.capture2('/usr/bin/security', 'list-keychains', '-d', 'user')
    raise 'Could not read native keychain search list' unless original_status.success?
    env = { 'PATH' => ENV.fetch('PATH'), '__ETC_ZSHENV_SOURCED' => '1', 'RUNNER_TEMP' => directory,
      'TESTFLIGHT_SIGNING_KEY' => key.to_pem, 'TESTFLIGHT_CERTIFICATE' => certificate.to_der.unpack1('H*') }
    output, status = Open3.capture2e(env, '/bin/zsh', "#{root}/scripts/testflight-signing.zsh", '/usr/bin/false', unsetenv_others: true)
    # A self-signed fixture must import successfully, then fail Apple's trust check.
    raise "Native identity import failed: #{output}" unless status.exitstatus == 1 && output.include?('The prepared TestFlight identity is not valid for code signing')
    restored, restored_status = Open3.capture2('/usr/bin/security', 'list-keychains', '-d', 'user')
    raise 'Native search list not restored' unless restored_status.success? && restored == original
    raise 'Native signing material retained' unless Dir.glob("#{directory}/testflight-signing.*").empty?
    puts 'Passed native TestFlight identity import and cleanup'
    next
  end
  bin = "#{directory}/bin"
  FileUtils.mkdir_p(bin)
  File.write("#{bin}/security", <<~'STUB')
    #!/usr/bin/env ruby
    require 'json'
    require 'openssl'
    require 'shellwords'
    at_exit { warn 'SECURITY_DIAGNOSTIC_SECRET_SENTINEL' if $!.is_a?(SystemExit) && !$!.success? }
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
      exit 17 if !ARGV.include?('-s') && ENV['SCENARIO'] == 'read-search-list-failure'
      puts '    "/original/login with spaces.keychain-db"' unless ARGV.include?('-s')
      exit 1 if ARGV.include?('-s') && ENV['SCENARIO'] == 'restore-failure' && ARGV.last.start_with?('/original/')
      exit 19 if ARGV.include?('-s') && ENV['SCENARIO'] == 'set-search-list-failure' && !ARGV.last.start_with?('/original/')
    when 'import'
      path = ARGV.fetch(1)
      raise 'Readable private material' unless File.stat(path).mode & 0o077 == 0
      if ARGV.fetch(ARGV.index('-t') + 1) == 'priv'
        raise 'Invalid private key' unless OpenSSL::PKey.read(File.binread(path)).private?
        exit 23 if ENV['SCENARIO'] == 'import-key-failure'
      else
        certificate = OpenSSL::X509::Certificate.new(File.binread(path))
        key = OpenSSL::PKey.read(File.binread("#{File.dirname(path)}/key.pem"))
        raise 'Invalid signing identity' unless certificate.check_private_key(key)
        exit 31 if ENV['SCENARIO'] == 'import-certificate-failure'
      end
    when 'create-keychain', 'set-keychain-settings', 'unlock-keychain', 'set-key-partition-list'
      exit 1 if ENV['SCENARIO'] == "#{operation}-failure"
    when 'find-identity'
      exit 29 if ENV['SCENARIO'] == 'find-identity-failure'
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
    'read-search-list-failure' => 17, 'set-search-list-failure' => 19, 'find-identity-failure' => 29,
    'create-keychain-failure' => 1, 'set-keychain-settings-failure' => 1,
    'unlock-keychain-failure' => 1, 'import-key-failure' => 23, 'import-certificate-failure' => 31,
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
    raise 'Secret reached diagnostics' if output.include?('PRIVATE KEY') || output.include?('INVALID_CERTIFICATE_SENTINEL') || output.include?('SECURITY_DIAGNOSTIC_SECRET_SENTINEL')
    raise "#{scenario}: temporary signing material retained" unless Dir.glob("#{run}/testflight-signing.*").empty?
    setup_failed = scenario.end_with?('-failure') && !%w[restore-failure delete-failure].include?(scenario)
    if setup_failed
      stage = scenario.delete_suffix('-failure')
      raise "#{scenario}: missing safe failure diagnostic" unless output.include?("TestFlight signing failed during #{stage} (exit #{expected})")
      raise 'Signing setup failure reached upload' if File.exist?("#{run}/uploaded")
    elsif %w[restore-failure delete-failure].include?(scenario)
      stage = scenario == 'restore-failure' ? 'restore-search-list' : 'delete-keychain'
      raise "#{scenario}: missing safe cleanup diagnostic" unless output.include?("TestFlight signing cleanup failed during #{stage} (exit 1)")
    end
    if %w[malformed expired].include?(scenario)
      raise 'Invalid certificate reached keychain' if File.exist?("#{run}/calls")
    elsif scenario == 'read-search-list-failure'
      raise 'Search-list failure mutated keychains' unless File.readlines("#{run}/calls").map { |line| JSON.parse(line) } == [['list-keychains', '-d', 'user']]
    else
      calls = File.readlines("#{run}/calls").map { |line| JSON.parse(line) }
      raise 'Original keychain search list not restored' unless calls[-2] == ['list-keychains', '-d', 'user', '-s', '/original/login with spaces.keychain-db']
      raise 'Temporary keychain not deleted' unless calls.last == ['delete-keychain']
      raise 'Missing signing identity reached upload' if scenario == 'missing-identity' && File.exist?("#{run}/uploaded")
    end
  end
  puts 'Passed TestFlight keychain contracts: import, isolation, failure, signals and cleanup'
end
