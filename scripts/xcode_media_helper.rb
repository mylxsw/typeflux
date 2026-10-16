# frozen_string_literal: true

# Keep the checked-in project and its generator on the same native tool target.
def add_media_helper(project, app_target, team_id)
  helper = project.new_target(:command_line_tool, 'TypefluxMediaHelper', :osx, '13.0', nil, :swift)
  source = project.main_group.new_file('Sources/TypefluxMediaHelper/TypefluxMediaHelper.swift')
  helper.source_build_phase.add_file_reference(source)
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.product_name = 'TypefluxMediaWorkerKit'
  helper.package_product_dependencies << product
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product
  helper.frameworks_build_phase.files << build_file
  helper.build_configurations.each do |config|
    config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
    config.build_settings['SWIFT_VERSION'] = '5.0'
    config.build_settings['DEVELOPMENT_TEAM'] = team_id
    config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
    config.build_settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
    config.build_settings['SKIP_INSTALL'] = 'YES'
  end
  app_target.add_dependency(helper)
  copy = app_target.new_copy_files_build_phase('Embed media helper')
  copy.dst_subfolder_spec = '6'
  copy.dst_path = '../Helpers'
  embedded = copy.add_file_reference(helper.product_reference)
  embedded.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy'] }
end
