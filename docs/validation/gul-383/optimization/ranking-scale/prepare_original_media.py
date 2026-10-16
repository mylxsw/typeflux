#!/usr/bin/env python3
"""Populate the original supported video fixtures; scanned PDFs remain explicitly unsupported."""
import argparse,hashlib,json,shutil,subprocess,time,wave
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--assets',type=Path,required=True);a=p.parse_args()
here=Path(__file__).parent;labels=json.loads((here.parent/'queries.json').read_text());a.assets.mkdir(parents=True,exist_ok=True)
assert shutil.which('ffmpeg'), 'ffmpeg is a fixture-generation dependency only, not an application dependency'
start=time.monotonic();records=[]
for doc in labels['documents']:
 if doc['kind'] in ['text','long_tail']:
  path=a.assets/(doc['id']+'.txt');path.write_text(doc['text'])
 elif doc['kind'] in ['video','audio']:
  speech=a.assets/(doc['id']+'.aiff');wav=a.assets/(doc['id']+'-speech.wav');timeline=a.assets/(doc['id']+'-timeline.wav');path=a.assets/(doc['id']+('.mov' if doc['kind']=='video' else '.wav'))
  subprocess.run(['/usr/bin/say','-v','Samantha','-o',str(speech),doc['text']],check=True,stdout=subprocess.DEVNULL)
  subprocess.run(['/usr/bin/afconvert','-f','WAVE','-d','LEI16@16000','-c','1',str(speech),str(wav)],check=True,stdout=subprocess.DEVNULL)
  with wave.open(str(wav)) as f:raw=f.readframes(f.getnframes());duration=f.getnframes()/f.getframerate()
  silence=bytes(int(doc['time']*16000)*2)
  with wave.open(str(timeline),'wb') as f:f.setnchannels(1);f.setsampwidth(2);f.setframerate(16000);f.writeframes(silence+raw+bytes(32000))
  if doc['kind']=='video':subprocess.run(['ffmpeg','-nostdin','-loglevel','error','-y','-f','lavfi','-i','color=c=gray:s=128x128:r=1','-i',str(timeline),'-c:v','mjpeg','-q:v','5','-c:a','pcm_s16le','-shortest',str(path)],check=True)
  else:shutil.copy2(timeline,path)
  records.append(dict(id=doc['id'],kind=doc['kind'],anchor_start=doc['time'],anchor_end=doc['time']+duration,sha256=hashlib.sha256(path.read_bytes()).hexdigest(),bytes=path.stat().st_size))
  # Keep the formal corpus restricted to supported source files; preparation intermediates are private.
  for temporary in [speech,wav,timeline]:temporary.unlink()
 else:continue
 print(doc['id'],flush=True)
assert len(records)==25 and sum(x['kind']=='audio' for x in records)==12 and sum(x['kind']=='video' for x in records)==13
assert all((a.assets/(x['id']+('.mov' if x['kind']=='video' else '.wav'))).is_file() for x in records)
result=dict(records=records,wall_seconds=time.monotonic()-start,unsupported=dict(scanned_pdf=25),scope='75 original text documents,13 actual MOV/PCM inputs and12 actual WAV inputs. Speech anchor starts at the original frozen timestamp; solid-colour video is a declared generated fixture, not natural video. The 25 scanned PDF targets remain absent/unsupported and remain failures in the original 175-positive denominator.')
(here/'rework-original-media-assets-complete.json').write_text(json.dumps(result,indent=2)+'\n')
