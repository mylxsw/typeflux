import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class InferencePackagingTests(unittest.TestCase):
    def test_missing_helper_or_resources_cannot_produce_a_partial_install(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            binary = root / 'bin'
            binary.mkdir()
            app = root / 'Typeflux.app'
            command = ['bash', str(ROOT / 'scripts/copy_inference_helper.sh'), str(binary), str(app)]
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            helper = binary / 'TypefluxInferenceHelper'
            helper.write_text('#!/bin/sh\nexit 0\n')
            helper.chmod(0o755)
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertFalse(app.exists())
            resources = binary / 'swift-transformers_Hub.bundle'
            resources.mkdir()
            (resources / 'tokenizer.json').write_text('{}')
            subprocess.run(command, check=True)
            self.assertEqual((app / 'Contents/Helpers/TypefluxInferenceHelper').read_bytes(), helper.read_bytes())
            packaged = app / 'Contents/Helpers/swift-transformers_Hub.bundle'
            self.assertTrue((packaged / 'Contents/Resources/tokenizer.json').is_file())
            self.assertTrue((packaged / 'Contents/Info.plist').is_file())
            subprocess.run(['codesign', '--force', '--sign', '-', str(packaged)], check=True)
            lookup = '''import Foundation
let bundle = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
guard bundle.url(forResource: "tokenizer", withExtension: "json") != nil else { exit(1) }
'''
            subprocess.run(['swift', '-e', lookup, str(packaged)], check=True)

    def test_xcode_app_embeds_both_worker_and_tokenizer_resources(self):
        script = r'''
require 'xcodeproj'
p = Xcodeproj::Project.open(ARGV[0])
app = p.targets.find { |t| t.name == 'TypefluxApp' }
helper = p.targets.find { |t| t.name == 'TypefluxInferenceHelper' }
abort 'missing dependency' unless app.dependencies.any? { |d| d.target == helper }
abort 'wrong runtime' unless helper.package_product_dependencies.map(&:product_name) == ['TypefluxInferenceWorkerKit']
phase = app.copy_files_build_phases.find { |b| b.name == 'Embed inference helper' }
abort 'wrong destination' unless phase.dst_subfolder_spec == '6' && phase.dst_path == '../Helpers'
paths = phase.files.map { |f| f.file_ref.path }
abort 'missing helper resources' unless paths.sort == ['TypefluxInferenceHelper', 'swift-transformers_Hub.bundle'].sort
abort 'deployment target changed' unless helper.build_configurations.all? { |c| c.build_settings['MACOSX_DEPLOYMENT_TARGET'] == '13.0' }
'''
        subprocess.run(['/usr/bin/ruby', '-e', script, str(ROOT / 'TypefluxApp.xcodeproj')], check=True)


if __name__ == '__main__':
    unittest.main()
