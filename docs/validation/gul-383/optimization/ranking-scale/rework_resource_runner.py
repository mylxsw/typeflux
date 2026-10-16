#!/usr/bin/env python3
"""Foreground command owner. Sample only numeric host/resource data and process basenames."""
import argparse,json,os,plistlib,subprocess,time
from pathlib import Path
from darwin_process_metrics import snapshot as process_metrics
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('command',nargs=argparse.REMAINDER);a=p.parse_args();cmd=a.command
if cmd and cmd[0]=='--':cmd=cmd[1:]
if not cmd:p.error('explicit foreground command required')
a.output.mkdir(parents=True,exist_ok=True)
def read(command):
 try:return subprocess.check_output(command,text=True,stderr=subprocess.DEVNULL,timeout=8).strip()
 except (OSError,subprocess.SubprocessError):return None

def gpu():
 try:
  data=subprocess.check_output(['/usr/sbin/ioreg','-r','-c','IOAccelerator','-a','-d','1'],stderr=subprocess.DEVNULL,timeout=8)
  rows=plistlib.loads(data);out=[]
  for row in rows:
   values=row.get('PerformanceStatistics',{})
   out.append({k:v for k,v in values.items() if isinstance(v,(int,float)) and any(x in k.lower() for x in ['utilization','memory','bandwidth','activity','power','frequency'])})
  return out
 except (OSError,subprocess.SubprocessError,plistlib.InvalidFileException):return None
start=time.monotonic();wall=time.time();samples=[]
with (a.output/'command.log').open('w') as log:
 child=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT)
 try:
  while child.poll() is None:
   listing=read(['ps','-axo','pid=,ppid=,rss=,%cpu=,time=,comm=']) or ''
   parsed=[x.split(maxsplit=5) for x in listing.splitlines()];parsed=[x for x in parsed if len(x)==6]
   descendants={child.pid}
   while True:
    grown=descendants|{int(x[0]) for x in parsed if int(x[1]) in descendants}
    if grown==descendants:break
    descendants=grown
   owned=[dict(pid=int(pid),parent=int(parent),rss_bytes=int(rss)*1024,lifetime_cpu_percent=float(cpu),cpu_time=cpu_time,name=Path(name).name,rusage=process_metrics(int(pid))) for pid,parent,rss,cpu,cpu_time,name in parsed if int(pid) in descendants]
   external_rows=[dict(pid=int(pid),name=Path(name).name,cpu_time=cpu_time,rss_bytes=int(rss)*1024,lifetime_cpu_percent=float(cpu)) for pid,parent,rss,cpu,cpu_time,name in parsed if int(pid) not in descendants and Path(name).name in ['swift-frontend','swift-build','clang','swiftpm-testing-helper','xctest']]
   external=sum(float(cpu) for pid,parent,rss,cpu,cpu_time,name in parsed if int(pid) not in descendants and Path(name).name in ['swift-frontend','swift-build','clang','swiftpm-testing-helper','xctest'])
   samples.append(dict(seconds=time.monotonic()-start,unix=time.time(),owned=owned,external_compiler_test_cpu_percent=external,external_compiler_processes=external_rows,vm_stat=read(['/usr/bin/vm_stat']),swap=read(['/usr/sbin/sysctl','vm.swapusage']),pressure=read(['/usr/sbin/sysctl','kern.memorystatus_vm_pressure_level']),disk=read(['/usr/sbin/iostat','-Id','disk0']),gpu_statistics=gpu(),thermal=read(['/usr/bin/pmset','-g','therm'])))
   (a.output/'resources.json').write_text(json.dumps(dict(started_unix=wall,samples=samples),separators=(',',':'))+'\n')
   deadline=time.monotonic()+2
   while child.poll() is None and time.monotonic()<deadline:time.sleep(.1)
 finally:
  # The command is foreground owned; collect completion instead of leaving children behind.
  code=child.wait()
result=dict(command=cmd,started_unix=wall,wall_seconds=time.monotonic()-start,exit_code=code,samples=len(samples),scope='Same-host reference window and real mixed-file indexing. CPU process time is cumulative; %CPU is lifetime averaged. Owned proc_pid_rusage V2 records sampled physical footprint, physical disk IO and CPU Mach ticks converted using the host timebase; its CPU units were cross-checked against process_time_ns. Unsupported/denied PID reads retain available=false and errno. RSS includes shared resident pages; summed RSS is not unique physical RAM. GPU metrics are best-effort IOAccelerator counters, not energy measurements. No privileged powermetrics, external process arguments, filenames or input contents collected.')
(a.output/'run.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result));raise SystemExit(code)
