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
target.add_file_references(%w[main.mm AppDelegate.mm UnwiredCommands.m].map { |name| group.new_file(name) })
group.new_file('AppDelegate.h')
group.new_file('Info.plist')
icon = project.main_group.new_file('../../../native/app-icon/UnwiredMail.icon')
target.resources_build_phase.add_file_reference(icon)
info = Xcodeproj::Plist.read_from_path('UnwiredMail/Info.plist')
info.delete('UnwiredMockScenario')
info['CFBundleShortVersionString'] = JSON.parse(File.read('../package.json')).fetch('version')
# Release uploads stamp their UTC build number and source commit.
build_number = ENV.fetch('UNWIRED_BUILD_NUMBER', '1')
raise 'Invalid release build number' unless build_number.match?(/\A[0-9]+\z/)
info['CFBundleVersion'] = build_number
info.delete('UnwiredCommit')
info['UnwiredCommit'] = ENV['UNWIRED_COMMIT'] unless ENV.fetch('UNWIRED_COMMIT', '').empty?
client_id = ENV.fetch('UNWIRED_GOOGLE_CLIENT_ID', '')
raise 'Invalid native Google OAuth client ID' unless client_id.empty? || client_id.match?(/\A[0-9A-Za-z-]+\.apps\.googleusercontent\.com\z/)
info['GIDClientID'] = client_id
microsoft_client_id = ENV.fetch('UNWIRED_MICROSOFT_CLIENT_ID', '').downcase
raise 'Invalid Microsoft application client ID' unless microsoft_client_id.empty? || microsoft_client_id.match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/)
info['UnwiredMicrosoftClientID'] = microsoft_client_id
info['UnwiredConvexURL'] = ENV.fetch('UNWIRED_CONVEX_URL', '')
info['UnwiredErrorReportingQualification'] = ENV['UNWIRED_ERROR_REPORTING_QUALIFICATION'] == '1'
info['UnwiredNativeErrorReportingQualified'] = ENV['UNWIRED_NATIVE_ERROR_REPORTING_QUALIFIED'] == '1'
reporting_channel = ENV.fetch('UNWIRED_ERROR_REPORTING_CHANNEL', info['UnwiredErrorReportingQualification'] ? 'qualification' : 'production')
raise 'Invalid error reporting channel' unless %w[production testflight qualification].include?(reporting_channel)
info['UnwiredErrorReportingChannel'] = reporting_channel
# The Cloud Pub/Sub topic Gmail watches publish to; without one no push route is registered.
info.delete('UnwiredGmailTopic')
info['UnwiredGmailTopic'] = ENV['UNWIRED_GMAIL_PUBSUB_TOPIC'] unless ENV.fetch('UNWIRED_GMAIL_PUBSUB_TOPIC', '').empty?
info['CFBundleURLTypes'] = client_id.empty? ? [] : [{ 'CFBundleURLSchemes' => [client_id.split('.').reverse.join('.')] }]
Xcodeproj::Plist.write_to_path(info, 'UnwiredMail/Info.generated.plist')
info['UnwiredMockScenario'] = scenario if scenario
Xcodeproj::Plist.write_to_path(info, 'UnwiredMail/Info.testing.plist')
private_inbox = project.main_group.new_group('PrivateInbox', '../../../native/private-inbox')
# Only registration Mock Mail Session projects compile the synthetic relay and providers.
folders = scenario&.start_with?('registration-') ? 'Sources/PrivateInbox,bridge,synthetic' : 'Sources/PrivateInbox,bridge'
Dir.glob("../../../native/private-inbox/{#{folders}}/*.{swift,m}").each do |file|
  name = file.delete_prefix('../../../native/private-inbox/')
  target.add_file_references([private_inbox.new_file(name)])
end
# Private Inbox's Swift packages, pinned in its manifest; the build adopts its Package.resolved.
manifest = File.read('../../../native/private-inbox/Package.swift')
products = manifest.scan(/\.product\(name: "([^"]+)", package: "([^"]+)"\)/)
manifest.scan(/url: "([^"]+)",\s*revision: "([0-9a-f]{40})"/) do |url, revision|
  package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package.repositoryURL = url
  package.requirement = { 'kind' => 'revision', 'revision' => revision }
  project.root_object.package_references << package
  products.select { |_, name| name == File.basename(url, '.git') }.each do |product_name, _|
    product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    product.package = package
    product.product_name = product_name
    target.package_product_dependencies << product
    target.frameworks_build_phase.add_file_reference(nil).product_ref = product
  end
end
# Spike #831: only its Mock Mail Session build compiles the Core ML runner and bundles the models.
if scenario == 'categorization-spike'
  spike = project.main_group.new_group('CategorizationSpike', '../../../native/categorization-spike')
  Dir.glob('../../../native/categorization-spike/{Sources/CategorizationSpike,bridge}/*.{swift,m}').sort.each do |file|
    target.add_file_references([spike.new_file(file.delete_prefix('../../../native/categorization-spike/'))])
  end
  resources = target.new_shell_script_build_phase('Bundle categorization spike')
  resources.shell_script = <<~SH
    set -e
    spike="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/CategorizationSpike"
    mkdir -p "$spike"
    cp "$SRCROOT/../../../tools/system-category-benchmark/custom/golden-v1.json" "$SRCROOT/../../../tools/system-category-benchmark/custom/categories-v1.json" "$spike/"
    # Exported by tools/deberta-mac-spike/export.py; without them the page reports the models unavailable.
    models="$SRCROOT/../../../tools/deberta-mac-spike/work/models"
    if [ -d "$models" ]; then rsync -a --delete --exclude '*.mlpackage' "$models/" "$spike/models/"; else rm -rf "$spike/models"; fi
  SH
  resources.always_out_of_date = '1'
end
localization = project.main_group.new_group('Localization', '../../../native/localization')
target.add_file_references(%w[UnwiredLocalization.m UnwiredLanguagePreferences.m].map { |name| localization.new_file(name) })
localization.new_file('UnwiredLanguagePreferences.h')
design = project.main_group.new_group('Design', '../../../native/design')
target.add_file_references([design.new_file('UnwiredDesign.m')])
catalogs = project.main_group.new_file('../../../packages/localization/catalogs.bundle')
target.resources_build_phase.add_file_reference(catalogs)
project.add_build_configuration('Testing', :release)
target.add_build_configuration('Testing', :release)
project.build_configurations.each do |configuration|
  configuration.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '27.0'
end
# Automatic signing only selects Xcode-managed profiles; an installed portal profile needs Manual.
profile = ENV['UNWIRED_MAC_PROFILE']
profile = nil if profile == ''
profile_uuid = profile && IO.popen(['security', 'cms', '-D', '-i', profile], &:read)[%r{<key>UUID</key>\s*<string>([^<]+)</string>}, 1]
abort "Cannot read the UUID of UNWIRED_MAC_PROFILE #{profile}" if profile && !profile_uuid
target.build_configurations.each do |configuration|
  configuration.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'dev.unwired.mail',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'UnwiredMail',
    'INFOPLIST_FILE' => configuration.name == 'Testing' ? 'UnwiredMail/Info.testing.plist' : 'UnwiredMail/Info.generated.plist',
    'UNWIRED_MOCK_SCENARIO' => configuration.name == 'Testing' ? (scenario || '') : '',
    'CLANG_ENABLE_OBJC_ARC' => 'YES',
    'CLANG_ENABLE_MODULES' => 'YES',
    'HEADER_SEARCH_PATHS' => ['$(inherited)', '$(SRCROOT)/../../../native/localization'],
    'SWIFT_VERSION' => '5.0',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => ['$(inherited)',
      configuration.name == 'Testing' && scenario ? 'UNWIRED_ASSISTANCE_MOCK' : '',
      configuration.name == 'Testing' && scenario&.start_with?('registration-') ? 'UNWIRED_REGISTRATION_MOCK' : ''],
    'MACOSX_DEPLOYMENT_TARGET' => '27.0',
    'ENABLE_HARDENED_RUNTIME' => configuration.name == 'Release' ? 'YES' : 'NO',
    'CODE_SIGN_IDENTITY' => ENV.fetch('UNWIRED_SIGNING_IDENTITY', '-'),
    'CODE_SIGN_STYLE' => ENV.fetch('UNWIRED_SIGNING_IDENTITY', '-').start_with?('Apple Development') && !profile_uuid ? 'Automatic' : 'Manual',
    'PROVISIONING_PROFILE_SPECIFIER' => profile_uuid || '',
    'DEVELOPMENT_TEAM' => ENV.fetch('UNWIRED_DEVELOPMENT_TEAM', ''),
    'CODE_SIGN_ENTITLEMENTS' => ENV.fetch('UNWIRED_SIGNING_IDENTITY', '-') == '-' ? 'UnwiredMail/UnwiredMail.adhoc.entitlements' : 'UnwiredMail/UnwiredMail.entitlements',
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
  if [ -n "$SOURCEMAP_FILE" ]; then cp dist/main.jsbundle.map "$SOURCEMAP_FILE"; fi
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
