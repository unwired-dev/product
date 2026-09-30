require 'xcodeproj'

project = Xcodeproj::Project.new('WindowProbe.xcodeproj')
target = project.new_target(:ui_test_bundle, 'WindowProbe', :osx, '27.0')
target.add_file_references([project.main_group.new_file('WindowTests.swift')])
target.build_configurations.each do |configuration|
  configuration.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'dev.unwired.mail.macos.window-probe',
    'SWIFT_VERSION' => '5.0',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'CODE_SIGN_IDENTITY' => '-',
    'ENABLE_APP_SANDBOX' => 'NO',
    'MACOSX_DEPLOYMENT_TARGET' => '27.0'
  })
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(target)
scheme.test_action.should_use_launch_scheme_args_env = false
scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new(
  %w[UNWIRED_APP_PATH UNWIRED_TEST_SCENARIO].map { |key| { :key => key, :value => ENV.fetch(key) } }
)
scheme.save_as(project.path, 'WindowProbe', true)
