#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "CreatorStudio.xcodeproj")

# Single source of truth shared with Swift's `CaptureInboxLocation`. A mismatch
# between the entitlements and the identifiers the code uses fails silently at
# runtime: the App Group container just resolves to nil.
IDENTIFIERS = JSON.parse(File.read(File.join(ROOT, "Configuration/identifiers.json")))
APP_GROUP_ID = IDENTIFIERS.fetch("appGroupID")
APP_BUNDLE_ID = IDENTIFIERS.fetch("appBundleID")
BROADCAST_BUNDLE_ID = IDENTIFIERS.fetch("broadcastExtensionBundleID")

abort "Unexpected project path" unless File.basename(PROJECT_PATH) == "CreatorStudio.xcodeproj"
FileUtils.rm_rf(PROJECT_PATH) if File.directory?(PROJECT_PATH)

def write_entitlements(path, app_group_id)
  File.write(path, <<~PLIST)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.security.application-groups</key>
        <array>
            <string>#{app_group_id}</string>
        </array>
    </dict>
    </plist>
  PLIST
end

write_entitlements(
  File.join(ROOT, "Apps/CreatorStudioApp/CreatorStudioApp.entitlements"),
  APP_GROUP_ID
)
write_entitlements(
  File.join(ROOT, "Extensions/CreatorBroadcast/CreatorBroadcast.entitlements"),
  APP_GROUP_ID
)

project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2630"
project.root_object.attributes["LastUpgradeCheck"] = "2630"

app = project.new_target(:application, "CreatorStudio", :ios, "18.0")
broadcast = project.new_target(:app_extension, "CreatorBroadcast", :ios, "18.0")

def configure_target(target, bundle_id, info_plist, entitlements, skip_install: false)
  target.build_configurations.each do |config|
    config.build_settings.merge!(
      "PRODUCT_BUNDLE_IDENTIFIER" => bundle_id,
      "PRODUCT_NAME" => "$(TARGET_NAME)",
      "MARKETING_VERSION" => "0.1.0",
      "CURRENT_PROJECT_VERSION" => "1",
      "SWIFT_VERSION" => "6.2",
      "SWIFT_STRICT_CONCURRENCY" => "complete",
      "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
      "GENERATE_INFOPLIST_FILE" => "NO",
      "INFOPLIST_FILE" => info_plist,
      "CODE_SIGN_ENTITLEMENTS" => entitlements,
      "IPHONEOS_DEPLOYMENT_TARGET" => "18.0",
      "SKIP_INSTALL" => skip_install ? "YES" : "NO"
    )
  end
end

configure_target(
  app,
  APP_BUNDLE_ID,
  "Apps/CreatorStudioApp/Info.plist",
  "Apps/CreatorStudioApp/CreatorStudioApp.entitlements"
)
configure_target(
  broadcast,
  BROADCAST_BUNDLE_ID,
  "Extensions/CreatorBroadcast/Info.plist",
  "Extensions/CreatorBroadcast/CreatorBroadcast.entitlements",
  skip_install: true
)

app.build_configurations.each do |config|
  config.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"
  config.build_settings["ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS"] = "YES"
end

broadcast.build_configurations.each do |config|
  config.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"
  config.build_settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
end

apps_group = project.main_group.new_group("Apps", "Apps")
app_group = apps_group.new_group("CreatorStudioApp", "CreatorStudioApp")
app_sources = app_group.new_group("Sources", "Sources")
Dir.glob(File.join(ROOT, "Apps/CreatorStudioApp/Sources/*.swift")).sort.each do |path|
  reference = app_sources.new_file(File.basename(path))
  app.source_build_phase.add_file_reference(reference)
end
app_group.new_file("Info.plist")
app_group.new_file("CreatorStudioApp.entitlements")

extensions_group = project.main_group.new_group("Extensions", "Extensions")
broadcast_group = extensions_group.new_group("CreatorBroadcast", "CreatorBroadcast")
broadcast_sources = broadcast_group.new_group("Sources", "Sources")
Dir.glob(File.join(ROOT, "Extensions/CreatorBroadcast/Sources/*.swift")).sort.each do |path|
  reference = broadcast_sources.new_file(File.basename(path))
  broadcast.source_build_phase.add_file_reference(reference)
end
broadcast_group.new_file("Info.plist")
broadcast_group.new_file("CreatorBroadcast.entitlements")

package_reference = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package_reference.relative_path = "."
project.root_object.package_references << package_reference

%w[
  StudioDomain
  StudioCapture
  StudioProjectStore
  StudioMediaPipeline
  StudioAI
  StudioExport
].each do |product_name|
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package_reference
  dependency.product_name = product_name
  app.package_product_dependencies << dependency

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  app.frameworks_build_phase.files << build_file
end

%w[StudioDomain StudioCapture].each do |product_name|
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package_reference
  dependency.product_name = product_name
  broadcast.package_product_dependencies << dependency

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  broadcast.frameworks_build_phase.files << build_file
end

app.add_dependency(broadcast)
embed_phase = app.new_copy_files_build_phase("Embed App Extensions")
embed_phase.dst_subfolder_spec = "13"
embed_file = embed_phase.add_file_reference(broadcast.product_reference, true)
embed_file.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app, true)
scheme.add_build_target(broadcast, false)
scheme.set_launch_target(app)
scheme.save_as(PROJECT_PATH, "CreatorStudio", true)

puts "Generated #{PROJECT_PATH}"
