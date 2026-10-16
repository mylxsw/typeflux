#!/usr/bin/env python3
"""Redact only new/modified evidence paths; preserve measured source/model/binary digests."""
import argparse,gzip,hashlib,json,re,subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--apply',action='store_true');a=p.parse_args();r=Path.cwd();h=Path(__file__).parent.resolve();paths=set(subprocess.check_output(['git','ls-files','--others','--exclude-standard','--',str(h.relative_to(r))],text=True).splitlines());paths.update(subprocess.check_output(['git','diff','--name-only','HEAD','--',str(h.relative_to(r))],text=True).splitlines());changed=[]
for name in sorted(paths):
 path=r/name
 if not path.is_file() or path.name=='evidence-redaction.json':continue
 raw=path.read_bytes();zipped=path.suffix=='.gz'
 try:decoded=(gzip.decompress(raw) if zipped else raw).decode('utf-8')
 except (UnicodeDecodeError,OSError):continue
 text=decoded
 if '.lcov' in path.name:text=text.replace('SF:'+str(r)+'/', 'SF:')
 text=text.replace(str(r),'<repository>').replace(str(r.parent),'<workspace>').replace(str(Path.home()),'<home>')
 text=re.sub(r'/(?:private/)?var/folders/[^\s"\'<>]+','<temporary>',text)
 if text==decoded:continue
 out=gzip.compress(text.encode(),mtime=0) if zipped else text.encode();changed.append(dict(path=name,original_sha256=hashlib.sha256(raw).hexdigest(),redacted_sha256=hashlib.sha256(out).hexdigest()))
 if a.apply:path.write_bytes(out)
if a.apply:(h/'evidence-redaction.json').write_text(json.dumps(dict(scope='Runtime repository/workspace/home and generated temporary path prefixes replaced in new/modified evidence only. LCOV project SF paths normalized relative to repository. Model/source/binary hashes remain the measured byte fingerprints, not redacted log fingerprints. Original file hashes retained for the redacted artifacts; no original private path mapping is exported.',files=changed),indent=2)+'\n')
print(json.dumps(dict(applied=a.apply,files=len(changed))))
