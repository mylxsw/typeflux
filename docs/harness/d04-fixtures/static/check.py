from pathlib import Path
assert '<h1>Launch ready</h1>' in Path('index.html').read_text()
print('PASS: standalone static page')
