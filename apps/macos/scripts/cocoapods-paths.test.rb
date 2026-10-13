require 'cocoapods'
require 'fileutils'
require 'tmpdir'
require_relative 'cocoapods-paths'

def assert(condition, message)
  raise message unless condition
end

def assert_raises(error_class)
  begin
    yield
  rescue error_class
    return
  end
  raise "Expected #{error_class}"
end

scratchpad = File.expand_path('../../../scratchpad', __dir__)
FileUtils.mkdir_p(scratchpad)
Dir.mktmpdir('cocoapods-paths-', scratchpad) do |directory|
  root = Pathname(directory).realpath
  package = root + 'node_modules/.pnpm/local-pod@1.0/node_modules/local-pod'
  FileUtils.mkdir_p(package + 'Sources/Nested')
  File.write(package + 'Sources/Nested/Example.h', '// source')
  %w[en cs].each do |locale|
    FileUtils.mkdir_p(package + "Resources/#{locale}.lproj")
    File.write(package + "Resources/#{locale}.lproj/Localizable.strings", '"hello" = "Hello";')
  end
  linked = root + 'app/node_modules/local-pod'
  FileUtils.mkdir_p(linked.dirname)
  File.symlink(package.relative_path_from(linked.dirname), linked)

  project = Pod::Project.new(root + 'Pods.xcodeproj')
  group = project.new_group('LocalPod', linked)
  base = linked + 'Sources'
  # Inject the observed Ruby failure at the filesystem boundary, not CocoaPods itself.
  base.define_singleton_method(:realdirpath) { raise ArgumentError, 'pathname contains null byte' }
  source = linked + 'Sources/Nested/Example.h'
  reference = project.add_file_reference(source, group, true, base)
  assert(reference.real_path == source.realpath, 'Symlinked source must resolve to the real file')
  assert(reference.parent.display_name == 'Nested', 'Source folder hierarchy must be preserved')
  assert(project.add_file_reference(source, group, true, base) == reference, 'Source references must be reused')

  resources = linked + 'Resources'
  %w[en cs].each do |locale|
    project.add_file_reference(resources + "#{locale}.lproj/Localizable.strings", group, true, resources)
  end
  variants = project.objects.grep(Xcodeproj::Project::Object::PBXVariantGroup)
  assert(variants.size == 1, 'Translations must share one variant group')
  assert(variants.first.display_name == 'Localizable.strings', 'Localized resource name must be retained')
  assert(variants.first.files.map { |file| file.real_path.realpath }.sort ==
    %w[cs en].map { |locale| (package + "Resources/#{locale}.lproj/Localizable.strings").realpath }.sort,
    'Both translations must resolve to their real files')

  ordinary = package + 'Ordinary.h'
  File.write(ordinary, '// ordinary')
  assert(project.add_file_reference(ordinary, group).real_path == ordinary, 'Paths without a base must still work')
  assert_raises(ArgumentError) { project.add_file_reference(Pathname('relative.h'), group) }
  File.write(package + 'Invalid.h', '// invalid base')
  assert_raises(ArgumentError) { project.add_file_reference(package + 'Invalid.h', group, true, Pathname('relative')) }
  assert_raises(Errno::ENOENT) { project.add_file_reference(linked + 'Missing.h', group, true, linked) }

  project.save
  reopened = Xcodeproj::Project.open(project.path)
  assert(reopened.files.all? { |file| file.real_path.file? }, 'Saved project file references must remain valid')
  assert(reopened.objects.grep(Xcodeproj::Project::Object::PBXVariantGroup).size == 1,
    'Localization must survive saving and reopening the project')
end
puts 'Verified CocoaPods symlinked sources, localized resources, and invalid-path failures.'
