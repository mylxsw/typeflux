# frozen_string_literal: true

def add_chat_window_helper(project, app_target, team_id, bundle_id)
  helper = project.new_target(:application, 'TypefluxChatWindowHelper', :osx, '13.0', nil, :swift)
  source = project.main_group.new_file('Sources/TypefluxChatWindowHelper/TypefluxChatWindowHelper.swift')
  helper.source_build_phase.add_file_reference(source)
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.product_name = 'TypefluxChatWindowKit'
  helper.package_product_dependencies << product
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product
  helper.frameworks_build_phase.files << build_file
  helper.build_configurations.each do |config|
    config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
    config.build_settings['SWIFT_VERSION'] = '5.9'
    config.build_settings['DEVELOPMENT_TEAM'] = team_id
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "#{bundle_id}.chat-window"
    config.build_settings['INFOPLIST_FILE'] = 'app/ChatWindowHelper-Info.plist'
    config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
    config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
    config.build_settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
    config.build_settings['SKIP_INSTALL'] = 'YES'
  end
  app_target.add_dependency(helper)
  copy = app_target.new_copy_files_build_phase('Embed chat window helper')
  copy.dst_subfolder_spec = '6'
  copy.dst_path = '../Helpers'
  embedded = copy.add_file_reference(helper.product_reference)
  embedded.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy'] }
end
