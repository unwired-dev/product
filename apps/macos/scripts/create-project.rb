require 'json'
require 'xcodeproj'

scenario = ENV['UNWIRED_MOCK_SCENARIO']
scenario = nil if scenario == ''
scenarios = JSON.parse(File.read(File.expand_path('../../../scripts/mock-mail-scenarios.json', __dir__)))
raise 'Unknown Mock Mail Session scenario' if scenario && !scenarios['build'].include?(scenario)
raise 'Mock scenarios require Testing configuration' if scenario && ENV['UNWIRED_BUILD_CONFIGURATION'] != 'Testing'

Dir.chdir(File.expand_path('../macos', __dir__))
project = Xcodeproj::Project.new('UnwiredMail.xcodeproj')
target = project.new_target(:application, 'UnwiredMail', :osx, '27.0')
group = project.main_group.new_group('UnwiredMail', 'UnwiredMail')
target.add_file_references(%w[main.mm AppDelegate.mm].map { |name| group.new_file(name) })
group.new_file('AppDelegate.h')
group.new_file('Info.plist')
icon = project.main_group.new_file('../../../native/app-icon/UnwiredMail.icon')
target.resources_build_phase.add_file_reference(icon)
info = Xcodeproj::Plist.read_from_path('UnwiredMail/Info.plist')
info.delete('UnwiredMockScenario')
info['CFBundleShortVersionString'] = JSON.parse(File.read('../package.json')).fetch('version')
client_id = ENV.fetch('UNWIRED_GOOGLE_CLIENT_ID', '')
raise 'Invalid native Google OAuth client ID' unless client_id.empty? || client_id.match?(/\A[0-9A-Za-z-]+\.apps\.googleusercontent\.com\z/)
info['GIDClientID'] = client_id
info['UnwiredConvexURL'] = ENV.fetch('UNWIRED_CONVEX_URL', '')
info['CFBundleURLTypes'] = client_id.empty? ? [] : [{ 'CFBundleURLSchemes' => [client_id.split('.').reverse.join('.')] }]
Xcodeproj::Plist.write_to_path(info, 'UnwiredMail/Info.generated.plist')
info['UnwiredMockScenario'] = scenario if scenario
Xcodeproj::Plist.write_to_path(info, 'UnwiredMail/Info.testing.plist')
private_inbox = project.main_group.new_group('PrivateInbox', '../../../native/private-inbox')
Dir.glob('../../../native/private-inbox/{Sources/PrivateInbox,bridge}/*.{swift,m}').each do |file|
  name = file.delete_prefix('../../../native/private-inbox/')
  target.add_file_references([private_inbox.new_file(name)])
end
project.add_build_configuration('Testing', :release)
target.add_build_configuration('Testing', :release)
project.build_configurations.each do |configuration|
  configuration.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '27.0'
end
target.build_configurations.each do |configuration|
  configuration.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'dev.unwired.mail',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'UnwiredMail',
    'INFOPLIST_FILE' => configuration.name == 'Testing' ? 'UnwiredMail/Info.testing.plist' : 'UnwiredMail/Info.generated.plist',
    'UNWIRED_MOCK_SCENARIO' => configuration.name == 'Testing' ? (scenario || '') : '',
    'CLANG_ENABLE_OBJC_ARC' => 'YES',
    'CLANG_ENABLE_MODULES' => 'YES',
    'SWIFT_VERSION' => '5.0',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => ['$(inherited)', configuration.name == 'Testing' && scenario&.start_with?('registration-') ? 'UNWIRED_REGISTRATION_MOCK' : ''],
    'MACOSX_DEPLOYMENT_TARGET' => '27.0',
    'ENABLE_HARDENED_RUNTIME' => configuration.name == 'Release' ? 'YES' : 'NO',
    'CODE_SIGN_IDENTITY' => ENV.fetch('UNWIRED_SIGNING_IDENTITY', '-'),
    'CODE_SIGN_STYLE' => ENV.fetch('UNWIRED_SIGNING_IDENTITY', '-').start_with?('Apple Development') ? 'Automatic' : 'Manual',
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
