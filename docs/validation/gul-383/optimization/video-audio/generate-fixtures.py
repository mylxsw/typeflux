#!/usr/bin/env python3
"""Freeze real MOVs once; tests only copy verified bytes, never invoke encoders."""
from pathlib import Path
import array
import hashlib
import json
import math
import struct
import subprocess
import tempfile
root = Path(__file__).resolve().parent
source = root.parent / 'video-frames/static-scene.mov'
commands = []
with tempfile.TemporaryDirectory() as scratch:
    for name, active, seconds, offset in [('boundary', (29, 31), 65, 0),
                                           ('silent-prefix', (52, 54), 65, 0),
                                           ('offset', (0, 31), 31, 7.5)]:
        samples = array.array('f', (math.sin(i * .17) * .1 if active[0] <= i / 16000 < active[1] else 0
                                  for i in range(seconds * 16000)))
        pcm = samples.tobytes()
        wav = Path(scratch) / 'tone.wav'
        wav.write_bytes(b'RIFF' + struct.pack('<I', len(pcm) + 36) + b'WAVEfmt '
                        + struct.pack('<IHHIIHH', 16, 3, 1, 16000, 64000, 4, 32)
                        + b'data' + struct.pack('<I', len(pcm)) + pcm)
        command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-stream_loop', '-1', '-i', str(source),
                   '-itsoffset', str(offset), '-i', str(wav), '-map', '0:v:0', '-map', '1:a:0',
                   '-t', str(seconds + offset), '-c:v', 'copy', '-c:a', 'pcm_f32le', str(root / (name + '.mov'))]
        subprocess.run(command, check=True)
        commands.append({'name': name, 'seconds': seconds, 'offset': offset, 'active': active,
                         'command': ['ffmpeg', 'loop frozen static-scene.mov; copy JPEG',
                                     'mux synthetic 16kHz float PCM; no video encoding'],
                         'sha256': hashlib.sha256((root / (name + '.mov')).read_bytes()).hexdigest()})
(root / 'fixture-manifest.json').write_text(json.dumps(commands, indent=2) + '\n')
