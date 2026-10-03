require 'xcodeproj'
require 'fileutils'

platform = ARGV.fetch(0) == 'macos' ? :osx : :ios
root = File.expand_path('..', __dir__)
output = File.expand_path(ENV.fetch('UNWIRED_STORAGE_PROBE'))
FileUtils.mkdir_p(output)
Dir.chdir(output)
project = Xcodeproj::Project.new('StorageProbe.xcodeproj')
host = project.new_target(:application, 'StorageHost', platform, '27.0')
File.write('Host.swift', <<~SWIFT)
  import SwiftUI
  @main struct StorageHost: App {
    var body: some Scene { WindowGroup { Text("Storage integration probe") } }
  }
SWIFT
host.add_file_references([project.main_group.new_file('Host.swift')])
tests = project.new_target(:unit_test_bundle, 'StorageProbe', platform, '27.0')
tests.add_dependency(host)
Dir.glob(File.join(root, 'Sources/PrivateInbox/*.swift')).each do |file|
  tests.add_file_references([project.main_group.new_file(file)])
end
Dir.glob(File.join(root, 'Tests/PrivateInboxTests/*.swift')).each do |file|
  name = File.basename(file)
  File.write(name, File.read(file).sub('@testable import PrivateInbox', ''))
  tests.add_file_references([project.main_group.new_file(name)])
end
[host, tests].each do |target|
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'PRODUCT_BUNDLE_IDENTIFIER' => "dev.unwired.storage-probe.#{target.name}",
      'SWIFT_VERSION' => '6.0',
      'GENERATE_INFOPLIST_FILE' => 'YES',
      'CODE_SIGN_IDENTITY' => ENV.fetch('UNWIRED_SIGNING_IDENTITY', '-'),
      'DEVELOPMENT_TEAM' => ENV.fetch('UNWIRED_DEVELOPMENT_TEAM', ''),
      'ENABLE_HARDENED_RUNTIME' => 'NO',
      'TARGETED_DEVICE_FAMILY' => '1,2',
      'INFOPLIST_KEY_UIApplicationSceneManifest_Generation' => 'YES',
      'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES'
    })
  end
end
if platform == :osx
  File.write('StorageHost.entitlements', <<~PLIST)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>com.apple.application-identifier</key><string>$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)</string>
      <key>keychain-access-groups</key><array><string>$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)</string></array>
      <key>com.apple.security.app-sandbox</key><true/>
      <key>com.apple.security.get-task-allow</key><true/>
    </dict></plist>
  PLIST
  host.build_configurations.each { |config| config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'StorageHost.entitlements' }
end
tests.build_configurations.each do |config|
  executable = platform == :osx ? 'Contents/MacOS/StorageHost' : 'StorageHost'
  config.build_settings['TEST_HOST'] = "$(BUILT_PRODUCTS_DIR)/StorageHost.app/#{executable}"
  config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(host)
scheme.add_build_target(tests)
scheme.add_test_target(tests)
scheme.save_as(project.path, 'StorageProbe', true)
