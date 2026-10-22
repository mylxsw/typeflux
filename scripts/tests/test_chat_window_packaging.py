import pathlib
import plistlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ChatWindowPackagingTests(unittest.TestCase):
    def test_bundle_has_a_distinct_parent_scoped_identity_and_no_entitlements(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            binary = root / 'bin'
            binary.mkdir()
            app = root / 'Typeflux.app'
            command = ['bash', str(ROOT / 'scripts/copy_chat_window_helper.sh'), str(binary), str(app)]
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            helper = binary / 'TypefluxChatWindowHelper'
            helper.write_text('#!/bin/sh\nexit 0\n')
            helper.chmod(0o755)
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            (app / 'Contents').mkdir(parents=True)
            with (app / 'Contents/Info.plist').open('wb') as f:
                plistlib.dump({'CFBundleIdentifier': 'example.development'}, f)
            subprocess.run(command, check=True)
            contents = app / 'Contents/Helpers/TypefluxChatWindowHelper.app/Contents'
            info = plistlib.loads((contents / 'Info.plist').read_bytes())
            self.assertEqual(info['CFBundleIdentifier'], 'example.development.chat-window')
            self.assertTrue(info['LSUIElement'])
            self.assertEqual(info['CFBundlePackageType'], 'APPL')
            self.assertEqual((contents / 'MacOS/TypefluxChatWindowHelper').read_bytes(), helper.read_bytes())
            self.assertEqual(sorted(p.name for p in contents.iterdir()), ['Info.plist', 'MacOS'])

    def test_xcode_embeds_signed_gui_helper_with_only_presentation_runtime(self):
        script = r'''
require 'xcodeproj'
p = Xcodeproj::Project.open(ARGV[0])
app = p.targets.find { |t| t.name == 'TypefluxApp' }
helper = p.targets.find { |t| t.name == 'TypefluxChatWindowHelper' }
abort 'missing GUI helper' unless helper.product_type == 'com.apple.product-type.application'
abort 'missing dependency' unless app.dependencies.any? { |d| d.target == helper }
abort 'wrong runtime' unless helper.package_product_dependencies.map(&:product_name) == ['TypefluxChatWindowKit']
phase = app.copy_files_build_phases.find { |b| b.name == 'Embed chat window helper' }
abort 'wrong destination' unless phase.dst_subfolder_spec == '6' && phase.dst_path == '../Helpers'
abort 'not signed' unless phase.files.first.settings['ATTRIBUTES'].include?('CodeSignOnCopy')
abort 'unexpected entitlements' if helper.build_configurations.any? { |c| c.build_settings.key?('CODE_SIGN_ENTITLEMENTS') }
'''
        subprocess.run(['/usr/bin/ruby', '-e', script, str(ROOT / 'TypefluxApp.xcodeproj')], check=True)
        for name in ['run_dev_app.sh', 'run_dev_attached.sh', 'build_release.sh']:
            text = (ROOT / 'scripts' / name).read_text()
            self.assertIn('copy_chat_window_helper.sh', text)
            self.assertIn('/Contents/Helpers/TypefluxChatWindowHelper.app"', text)
            subprocess.run(['bash', '-n', str(ROOT / 'scripts' / name)], check=True)


if __name__ == '__main__':
    unittest.main()
