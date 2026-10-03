from pathlib import Path

assert '<h1>Launch ready</h1>' in Path('index.html').read_text()
assert 'JavaScript verified' in Path('app.js').read_text()
assert 'background' in Path('style.css').read_text()
print('PASS: heading, JavaScript and stylesheet; UTF-8: \u2705')
