#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'TypefluxApp.xcodeproj')
TARGET_NAME = 'TypefluxApp'
PRODUCT_NAME = 'Typeflux'
MODULE_NAME = 'TypefluxAppRunner'
TEAM_ID = ENV.fetch('TYPEFLUX_DEVELOPMENT_TEAM', 'N95437SZ2A')
BUNDLE_ID = ENV.fetch('TYPEFLUX_BUNDLE_ID', 'ai.gulu.app.typeflux')

FileUtils.rm_rf(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes['LastSwiftUpdateCheck'] = '1640'
project.root_object.attributes['LastUpgradeCheck'] = '1640'

app_target = project.new_target(:application, TARGET_NAME, :osx, '13.0', nil, :swift, PRODUCT_NAME)
app_target.product_name = PRODUCT_NAME

sources_group = project.main_group.find_subpath('app', true)
main_file = sources_group.new_file('app/TypefluxXcodeMain.swift')
icon_file = sources_group.new_file('app/Typeflux.icns')
info_plist = sources_group.new_file('app/Info.plist')
entitlements = sources_group.new_file('app/Typeflux.entitlements')

app_target.source_build_phase.add_file_reference(main_file)
app_target.resources_build_phase.add_file_reference(icon_file)

package_reference = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package_reference.relative_path = '.'
project.root_object.package_references << package_reference

package_product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
package_product.product_name = 'TypefluxKit'
app_target.package_product_dependencies << package_product

framework_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
framework_build_file.product_ref = package_product
app_target.frameworks_build_phase.files << framework_build_file

app_target.build_configurations.each do |config|
    settings = config.build_settings
    settings['CODE_SIGN_STYLE'] = 'Automatic'
    settings['DEVELOPMENT_TEAM'] = TEAM_ID
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID
    settings['CODE_SIGN_ENTITLEMENTS'] = entitlements.path
    settings['INFOPLIST_FILE'] = info_plist.path
    settings['GENERATE_INFOPLIST_FILE'] = 'NO'
    settings['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
    settings['SWIFT_VERSION'] = '5.9'
    settings['SDKROOT'] = 'macosx'
    settings['SUPPORTED_PLATFORMS'] = 'macosx'
    settings['PRODUCT_NAME'] = PRODUCT_NAME
    settings['PRODUCT_MODULE_NAME'] = MODULE_NAME
    settings['ENABLE_APP_SANDBOX'] = 'NO'
    settings['ENABLE_HARDENED_RUNTIME'] = 'NO'
    settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = ''
end

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app_target, nil, launch_target: true)
scheme.save_as(PROJECT_PATH, TARGET_NAME, true)

project.save
