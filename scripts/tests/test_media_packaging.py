import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class MediaPackagingTests(unittest.TestCase):
    def test_missing_helper_or_resources_cannot_produce_a_partial_install(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            binary = root / 'bin'
            binary.mkdir()
            app = root / 'Typeflux.app'
            command = ['bash', str(ROOT / 'scripts/copy_media_helper.sh'), str(binary), str(app)]
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            helper = binary / 'TypefluxMediaHelper'
            helper.write_text('#!/bin/sh\nexit 0\n')
            helper.chmod(0o755)
            subprocess.run(command, check=True)
            self.assertEqual((app / 'Contents/Helpers/TypefluxMediaHelper').read_bytes(), helper.read_bytes())

    def test_xcode_app_embeds_both_worker_and_tokenizer_resources(self):
        script = r'''
require 'xcodeproj'
p = Xcodeproj::Project.open(ARGV[0])
app = p.targets.find { |t| t.name == 'TypefluxApp' }
helper = p.targets.find { |t| t.name == 'TypefluxMediaHelper' }
abort 'missing dependency' unless app.dependencies.any? { |d| d.target == helper }
abort 'wrong runtime' unless helper.package_product_dependencies.map(&:product_name) == ['TypefluxMediaWorkerKit']
phase = app.copy_files_build_phases.find { |b| b.name == 'Embed media helper' }
abort 'wrong destination' unless phase.dst_subfolder_spec == '6' && phase.dst_path == '../Helpers'
paths = phase.files.map { |f| f.file_ref.path }
abort 'missing helper resources' unless paths.sort == ['TypefluxMediaHelper'].sort
abort 'deployment target changed' unless helper.build_configurations.all? { |c| c.build_settings['MACOSX_DEPLOYMENT_TARGET'] == '13.0' }
'''
        subprocess.run(['/usr/bin/ruby', '-e', script, str(ROOT / 'TypefluxApp.xcodeproj')], check=True)


if __name__ == '__main__':
    unittest.main()
