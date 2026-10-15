# Adds the iOS app extensions to ios/Runner.xcodeproj (idempotent):
#   ShareExtension  "Lucero Sync" in the share sheet
#   LiveActivity    Lock Screen / Dynamic Island transfer progress
#
# Run with CocoaPods' Ruby, which bundles the xcodeproj gem:
#   GEM_HOME=$(brew --prefix)/Cellar/cocoapods/<ver>/libexec ruby tool/add_ios_extensions.rb
require 'xcodeproj'

ROOT = File.expand_path('../ios', __dir__)
project = Xcodeproj::Project.open(File.join(ROOT, 'Runner.xcodeproj'))
runner = project.targets.find { |t| t.name == 'Runner' }
config_names = project.build_configurations.map(&:name)

def group_for(project, name)
  project.main_group.children.find { |g| g.display_name == name } || project.main_group.new_group(name, name)
end

def file_ref(group, path)
  group.files.find { |f| f.path == path } || group.new_reference(path)
end

def add_source(target, ref)
  target.source_build_phase.add_file_reference(ref, true) unless target.source_build_phase.files_references.include?(ref)
end

shared = group_for(project, 'Shared')
app_group_ref = file_ref(shared, 'AppGroup.swift')
attrs_ref = file_ref(shared, 'LuceroActivityAttributes.swift')

# --- Runner ---------------------------------------------------------------
add_source(runner, app_group_ref)
add_source(runner, attrs_ref)
runner_group = project.main_group.children.find { |g| g.display_name == 'Runner' }
file_ref(runner_group, 'Runner.entitlements')
runner.build_configurations.each do |c|
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  flags = Array(c.build_settings['OTHER_LDFLAGS'] || ['$(inherited)'])
  flags << '-weak_framework' << 'ActivityKit' unless flags.include?('ActivityKit')
  c.build_settings['OTHER_LDFLAGS'] = flags
end

flutter_group = project.main_group.find_subpath('Flutter', false)
flutter_group.files.select { |f| f.path == 'Extension.xcconfig' }.each(&:remove_from_project)
ext_xcconfig = flutter_group.files.find { |f| f.path == 'Flutter/Extension.xcconfig' } ||
               flutter_group.new_reference('Flutter/Extension.xcconfig')

def make_extension(project, runner, config_names, xcconfig, name:, bundle_suffix:, deployment:, files:, entitlements: nil, frameworks: [])
  target = project.targets.find { |t| t.name == name }
  unless target
    target = project.new_target(:app_extension, name, :ios, deployment, nil, :swift)
  end
  # Configurations matching the project's (Debug, Release, Profile).
  config_names.each do |cn|
    next if target.build_configurations.any? { |c| c.name == cn }
    template = target.build_configurations.find { |c| c.name == (cn == 'Profile' ? 'Release' : 'Debug') }
    nc = target.add_build_configuration(cn, cn == 'Debug' ? :debug : :release)
    nc.build_settings.merge!(template.build_settings) if template
  end
  group = project.main_group.children.find { |g| g.display_name == name } || project.main_group.new_group(name, name)
  files.each { |f| add_source(target, f.is_a?(String) ? file_ref(group, f) : f) }
  file_ref(group, 'Info.plist')
  file_ref(group, File.basename(entitlements)) if entitlements
  frameworks.each do |fw|
    ref = project.frameworks_group.files.find { |f| f.path == "System/Library/Frameworks/#{fw}.framework" } ||
          project.frameworks_group.new_file("System/Library/Frameworks/#{fw}.framework", :sdk_root)
    target.frameworks_build_phase.add_file_reference(ref, true) unless target.frameworks_build_phase.files_references.include?(ref)
  end
  target.build_configurations.each do |c|
    c.base_configuration_reference = xcconfig
    s = c.build_settings
    s['PRODUCT_BUNDLE_IDENTIFIER'] = "$(APP_BUNDLE_ID).#{bundle_suffix}"
    s['PRODUCT_NAME'] = '$(TARGET_NAME)'
    s['INFOPLIST_FILE'] = "#{name}/Info.plist"
    s['GENERATE_INFOPLIST_FILE'] = 'NO'
    s['IPHONEOS_DEPLOYMENT_TARGET'] = deployment
    s['SWIFT_VERSION'] = '5.0'
    s['TARGETED_DEVICE_FAMILY'] = '1,2'
    s['CODE_SIGN_STYLE'] = 'Automatic'
    s['SKIP_INSTALL'] = 'YES'
    s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
    s['CODE_SIGN_ENTITLEMENTS'] = entitlements if entitlements
    s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
    s.delete('SWIFT_ACTIVE_COMPILATION_CONDITIONS') if c.name != 'Debug'
  end
  runner.add_dependency(target) unless runner.dependencies.any? { |d| d.target == target }
  target
end

share = make_extension(project, runner, config_names, ext_xcconfig,
                       name: 'ShareExtension', bundle_suffix: 'ShareExtension', deployment: '15.0',
                       files: ['ShareViewController.swift', app_group_ref],
                       entitlements: 'ShareExtension/ShareExtension.entitlements')
live = make_extension(project, runner, config_names, ext_xcconfig,
                      name: 'LiveActivity', bundle_suffix: 'LiveActivity', deployment: '16.2',
                      files: ['LuceroLiveActivity.swift', attrs_ref], frameworks: %w[WidgetKit SwiftUI])

# Embed both in the app, before "Thin Binary" (avoids a build cycle).
embed = runner.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' } ||
        runner.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
[share, live].each do |t|
  next if embed.files_references.include?(t.product_reference)
  bf = embed.add_file_reference(t.product_reference, true)
  bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
thin = runner.build_phases.find { |p| p.respond_to?(:name) && p.name == 'Thin Binary' }
if thin
  runner.build_phases.delete(embed)
  runner.build_phases.insert(runner.build_phases.index(thin), embed)
end

project.save
puts "Targets: #{project.targets.map(&:name).join(', ')}"
