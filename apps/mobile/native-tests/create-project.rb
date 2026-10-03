require 'xcodeproj'

project = Xcodeproj::Project.new('InboxProbe.xcodeproj')
target = project.new_target(:ui_test_bundle, 'InboxProbe', :ios, '27.0')
target.add_file_references([project.main_group.new_file('InboxTests.swift')])
target.build_configurations.each do |configuration|
  configuration.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'dev.unwired.mail.probe'
  configuration.build_settings['SWIFT_VERSION'] = '5.0'
  configuration.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  configuration.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  configuration.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
end
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(target)
scheme.test_action.should_use_launch_scheme_args_env = false
scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new(
  [{ :key => 'UNWIRED_BUNDLE_ID', :value => ENV.fetch('UNWIRED_BUNDLE_ID') },
   { :key => 'UNWIRED_TEST_SCENARIO', :value => ENV.fetch('UNWIRED_TEST_SCENARIO', 'open-read-relaunch') }]
)
scheme.save_as(project.path, 'InboxProbe')
