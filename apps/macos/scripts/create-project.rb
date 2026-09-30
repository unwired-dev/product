require 'xcodeproj'

scenario = ENV['UNWIRED_MOCK_SCENARIO']
raise 'Unknown Mock Mail Session scenario' if scenario && !%w[open-read-relaunch mail-unavailable].include?(scenario)
raise 'Mock scenarios require Testing configuration' if scenario && ENV['UNWIRED_BUILD_CONFIGURATION'] != 'Testing'

Dir.chdir(File.expand_path('../macos', __dir__))
project = Xcodeproj::Project.new('UnwiredMail.xcodeproj')
target = project.new_target(:application, 'UnwiredMail', :osx, '27.0')
group = project.main_group.new_group('UnwiredMail', 'UnwiredMail')
target.add_file_references(%w[main.mm AppDelegate.mm].map { |name| group.new_file(name) })
group.new_file('AppDelegate.h')
group.new_file('Info.plist')
info = Xcodeproj::Plist.read_from_path('UnwiredMail/Info.plist')
info.delete('UnwiredMockScenario')
info['UnwiredMockScenario'] = scenario if scenario
Xcodeproj::Plist.write_to_path(info, 'UnwiredMail/Info.generated.plist')
private_inbox = project.main_group.new_group('PrivateInbox', '../../../native/private-inbox')
%w[Sources/PrivateInbox/DeviceKeychain.swift Sources/PrivateInbox/PrivateInboxStore.swift Sources/PrivateInbox/SyntheticCredential.swift bridge/UnwiredPrivateInbox.swift bridge/UnwiredPrivateInboxBridge.m].each do |name|
  target.add_file_references([private_inbox.new_file(name)])
end
project.add_build_configuration('Testing', :release)
target.add_build_configuration('Testing', :release)
project.build_configurations.each do |configuration|
  configuration.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '27.0'
end
target.build_configurations.each do |configuration|
  configuration.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'dev.unwired.mail.macos.preview',
    'INFOPLIST_FILE' => configuration.name == 'Testing' && scenario ? 'UnwiredMail/Info.generated.plist' : 'UnwiredMail/Info.plist',
    'UNWIRED_MOCK_SCENARIO' => configuration.name == 'Testing' ? (scenario || '') : '',
    'CLANG_ENABLE_OBJC_ARC' => 'YES',
    'CLANG_ENABLE_MODULES' => 'YES',
    'SWIFT_VERSION' => '5.0',
    'MACOSX_DEPLOYMENT_TARGET' => '27.0',
    'ENABLE_HARDENED_RUNTIME' => configuration.name == 'Release' ? 'YES' : 'NO',
    'CODE_SIGN_IDENTITY' => ENV.fetch('UNWIRED_SIGNING_IDENTITY', '-'),
    'DEVELOPMENT_TEAM' => ENV.fetch('UNWIRED_DEVELOPMENT_TEAM', ''),
    'CODE_SIGN_ENTITLEMENTS' => ENV.fetch('UNWIRED_SIGNING_IDENTITY', '-') == '-' ? '' : 'UnwiredMail/UnwiredMail.entitlements',
    'COMBINE_HIDPI_IMAGES' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks'],
    'GCC_PREPROCESSOR_DEFINITIONS' => ['$(inherited)', configuration.name == 'Debug' ? 'DEBUG=1' : 'DEBUG=0',
      configuration.name == 'Testing' ? 'UNWIRED_NATIVE_TESTING=1' : 'UNWIRED_NATIVE_TESTING=0']
  })
end
bundle = target.new_shell_script_build_phase('Bundle Mac JavaScript')
bundle.shell_script = <<~SH
  set -e
  if [ "$CONFIGURATION" = "Debug" ]; then exit 0; fi
  cd "$SRCROOT/.."
  pnpm build
  pnpm verify:bundle
  mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
  cp dist/main.jsbundle "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/main.jsbundle"
SH
bundle.always_out_of_date = '1'
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.launch_action.build_configuration = 'Debug'
scheme.archive_action.build_configuration = 'Release'
scheme.save_as(project.path, 'UnwiredMail', true)
