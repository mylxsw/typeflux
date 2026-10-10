import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2] / 'Sources/Typeflux/WorkflowGallery'

def load(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/name/'main.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

class WorkflowToolsTests(unittest.TestCase):
    def test_html_entities_round_trip_unicode_quotes_and_numeric_entities(self):
        entities=load('entities')
        raw='<p title="你好">Tom & Jerry\'s</p>'
        escaped=entities.transform('-e '+raw)
        self.assertEqual(entities.transform('-d '+escaped),raw)
        self.assertEqual(entities.transform('-d','&#x1F680; &copy;'),'🚀 ©')
        with self.assertRaises(ValueError):entities.transform('-e')

    def test_subnet_ordinary_point_to_point_single_and_large_ranges(self):
        calculate=load('subnet').calculate
        def values(text):return {r['subtitle']:r['arg'] for r in json.loads(calculate(text))['items']}
        normal=values('192.168.1.42/24')
        self.assertEqual(normal['CIDR'],'192.168.1.0/24')
        self.assertEqual(normal['Usable hosts'],'254')
        self.assertEqual(normal['First host'],'192.168.1.1')
        self.assertEqual(normal['Last host'],'192.168.1.254')
        self.assertEqual(values('192.168.1.42 255.255.255.0'),normal)
        self.assertEqual(values('10.0.0.0/31')['Usable hosts'],'2')
        self.assertEqual(values('10.0.0.1/32')['First host'],'10.0.0.1')
        self.assertEqual(values('0.0.0.0/0')['Total addresses'],'4294967296')
        for text in ['::1/128','192.168.1.42','10.0.0.1/33','10.0.0.1 255.0.255.0']:
            with self.assertRaises(ValueError):calculate(text)

    def test_json_minify_typed_or_selected_and_report_errors(self):
        def run(query,selection=''):
            return subprocess.run([sys.executable,str(ROOT/'json/main.py'),query],input=json.dumps({'selection':selection})+'\n',text=True,capture_output=True)
        self.assertEqual(run('min { "a": 1 }').stdout,'{"a":1}\n')
        self.assertEqual(run('min','[1, 2]').stdout,'[1,2]\n')
        self.assertIn('\n  "a": 1\n',run('pretty','{"a":1}').stdout)
        self.assertEqual(run('{nope').returncode,1)

if __name__=='__main__':unittest.main()
