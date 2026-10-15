#!/bin/zsh
# Runs one SpikeProbe test against a disposable copy of a `categorization-spike` Testing build.
# Usage: run.zsh /path/to/Testing/UnwiredMail.app testMatrix|testDesignStates|testUnavailable
# Evidence (the app's JSONL results, captures, xcodebuild log) goes to artifacts/categorization-spike.*.
set -euo pipefail
source_app="${1:A}"
test_name="$2"
[[ -d "$source_app" && -n "$test_name" ]] || { print -u2 'Usage: run.zsh App.app testName'; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :UnwiredMockScenario' "$source_app/Contents/Info.plist") == categorization-spike ]] || {
  print -u2 'The probe requires a categorization-spike Testing build'; exit 1;
}
probe="${0:A:h}"
root="${probe:h:h:h}"
mkdir -p "$root/artifacts"
evidence=$(mktemp -d "$root/artifacts/categorization-spike.XXXXXX")
work=$(mktemp -d)
bundle="dev.unwired.mock.$(uuidgen | tr -d - | tr '[:upper:]' '[:lower:]')"
cleanup() {
  osascript -e "quit app id \"$bundle\"" 2>/dev/null || true
  rm -rf "$work" "$HOME/Library/Containers/$bundle"
}
trap cleanup EXIT

# A disposable identity keeps the ordinary app's container and data untouched.
cp -R "$source_app" "$work/UnwiredMail.app"
app="$work/UnwiredMail.app"
[[ "$test_name" == testUnavailable ]] && rm -rf "$app/Contents/Resources/CategorizationSpike/models"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle" "$app/Contents/Info.plist"
codesign -d --entitlements :- "$source_app" > "$work/entitlements.plist" 2>/dev/null
codesign --force --deep --sign - --entitlements "$work/entitlements.plist" "$app"

cp "$probe/SpikeProbe.swift" "$work/"
builtin cd -q "$work"
SPIKE_APP="$app" SPIKE_BUNDLE="$bundle" SPIKE_EVIDENCE="$evidence" "${RUBY:-ruby}" -rxcodeproj -e '
  project = Xcodeproj::Project.new("SpikeProbe.xcodeproj")
  target = project.new_target(:ui_test_bundle, "SpikeProbe", :osx, "27.0")
  target.add_file_references([project.main_group.new_file("SpikeProbe.swift")])
  target.build_configurations.each do |configuration|
    configuration.build_settings.merge!({
      "PRODUCT_BUNDLE_IDENTIFIER" => "dev.unwired.mail.macos.spike-probe", "SWIFT_VERSION" => "5.0",
      "GENERATE_INFOPLIST_FILE" => "YES", "CODE_SIGN_IDENTITY" => "-", "ENABLE_APP_SANDBOX" => "NO",
      "MACOSX_DEPLOYMENT_TARGET" => "27.0"
    })
  end
  project.save
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(target)
  scheme.add_test_target(target)
  scheme.test_action.should_use_launch_scheme_args_env = false
  scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new(
    %w[SPIKE_APP SPIKE_BUNDLE SPIKE_EVIDENCE].map { |key| { key: key, value: ENV.fetch(key) } })
  scheme.save_as(project.path, "SpikeProbe", true)'
xcodebuild test "-only-testing:SpikeProbe/SpikeProbe/$test_name" -project SpikeProbe.xcodeproj \
  -scheme SpikeProbe -destination 'platform=macOS' -derivedDataPath "$work/DerivedData" \
  -resultBundlePath "$evidence/SpikeProbe.xcresult" CODE_SIGN_IDENTITY=- ARCHS=arm64 \
  | tee "$evidence/xcodebuild.log" || true
results="$HOME/Library/Containers/$bundle/Data/tmp/categorization-spike.jsonl"
[[ -f "$results" ]] && cp "$results" "$evidence/"
/usr/bin/grep -q 'Executed 1 test, with 0 failures' "$evidence/xcodebuild.log"
print "Spike evidence: $evidence"
