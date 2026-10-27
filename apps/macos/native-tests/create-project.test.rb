require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require 'xcodeproj'

scratchpad = File.expand_path('../../../scratchpad', __dir__)
FileUtils.mkdir_p(scratchpad)
Dir.mktmpdir('mac-test-signing-', scratchpad) do |directory|
  File.write(File.join(directory, 'WindowTests.swift'), 'import XCTest')
  Dir.chdir(directory) do
    system({ 'UNWIRED_APP_PATH' => '/unused/Mock.app',
             'UNWIRED_TEST_SCENARIO' => 'open-read-relaunch' },
           RbConfig.ruby, File.join(__dir__, 'create-project.rb'), exception: true)
    project = Xcodeproj::Project.open('WindowProbe.xcodeproj')
    project.targets.fetch(0).build_configurations.each do |configuration|
      entitlements = configuration.build_settings['CODE_SIGN_ENTITLEMENTS']
      raise "#{configuration.name}: XCTest runner must override Xcode's sandbox entitlement" unless entitlements

      values = Xcodeproj::Plist.read_from_path(entitlements)
      unless values['com.apple.security.app-sandbox'] == false
        raise "#{configuration.name}: sandboxed XCTest launches can drop the app's probe environment"
      end
    end
  end
end
puts 'Verified the generated XCTest runner overrides the sandbox signing entitlement.'
