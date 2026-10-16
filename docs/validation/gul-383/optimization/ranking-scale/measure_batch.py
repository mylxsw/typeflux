#!/usr/bin/env python3
"""Compare the pinned serial encoder with true multi-sequence inference, preserving every sample."""
import argparse, hashlib, json, math, os, select, statistics, subprocess, tempfile, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

class Worker:
    def __init__(self,command):
        self.process=subprocess.Popen([str(x) for x in command],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        self.buffer=b''
        self.file_worker=len(command)>1 and str(command[-1])=='file-index-worker'
    def request(self,value):
        begin=time.monotonic()
        self.process.stdin.write(json.dumps(value,ensure_ascii=False).encode()+b'\n');self.process.stdin.flush()
        deadline=begin+120
        while b'\n' not in self.buffer:
            if not select.select([self.process.stdout],[],[],max(0,deadline-time.monotonic()))[0]:raise TimeoutError('helper')
            block=os.read(self.process.stdout.fileno(),65536)
            if not block:raise RuntimeError('helper exited')
            self.buffer+=block
        line,self.buffer=self.buffer.split(b'\n',1)
        reply=json.loads(line)
        while reply.get('more'):
            while b'\n' not in self.buffer:
                if not select.select([self.process.stdout],[],[],max(0,deadline-time.monotonic()))[0]:raise TimeoutError('frame')
                block=os.read(self.process.stdout.fileno(),65536)
                if not block:raise RuntimeError('file helper exited')
                self.buffer+=block
            line,self.buffer=self.buffer.split(b'\n',1)
            reply=json.loads(line)
        return reply,(time.monotonic()-begin)*1000
    def close(self):
        self.process.stdin.close()
        try:self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:self.process.kill();self.process.wait()
        self.process.stdout.close()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--before',type=Path,required=True);p.add_argument('--after',type=Path,required=True)
    p.add_argument('--model',type=Path,required=True);p.add_argument('--file-worker',type=Path,required=True)
    p.add_argument('--prefetch-only',action='store_true')
    a=p.parse_args()
    here=Path(__file__).parent
    text=('Mineral crystals form below basalt ridges. Quartz and granite contain silicate structures. '*20)[:1200]
    texts=['title: geology.txt | text: '+text+f' {i}' for i in range(16)]
    result={}
    target=here/'batch-prefetch.json'
    def checkpoint(): target.write_text(json.dumps(result,indent=2)+'\n')
    reference=[]
    if a.prefetch_only: result.update(json.loads(target.read_text()))
    for label,helper in ([] if a.prefetch_only else [('before',a.before),('after',a.after)]):
        worker=Worker([helper.resolve(),a.model.resolve()])
        try:
            vectors,_=worker.request(dict(texts=texts))
            assert not vectors.get('error'),vectors
            if label=='before':reference=vectors['embeddings']
            else:
                errors=[max(abs(x-y) for x,y in zip(one,two)) for one,two in zip(reference,vectors['embeddings'])]
                assert max(errors)<.001,errors
                result['maximum_component_error']=max(errors)
                assert all(abs(sum(x*x for x in v)-1)<.002 for v in vectors['embeddings'])
            rows=[]
            for batch in [1,2,4,8]:
                for n in range(100):
                    reply,ms=worker.request(dict(texts=texts[:batch]))
                    assert len(reply['embeddings'])==batch
                    rows.append(dict(batch=batch,round=n,milliseconds=ms))
            result[label]=dict(rows=rows,sha256=hashlib.sha256(helper.read_bytes()).hexdigest())
            checkpoint()
            for invalid in [dict(texts=[]),dict(texts=['']),dict(texts=['a'*1801]),dict(texts=['a']*17),
                            dict(media=dict(kind='image',path='/missing.png')),dict(texts=None)]:
                reply,_=worker.request(invalid);assert reply.get('error'),invalid
            # Long bilingual sequences force token-budget splitting and verify stable order.
            mixed=[texts[0],'title: 中文.txt | text: '+('项目报销流程需要发票和主管批准。'*27)]*8
            grouped,_=worker.request(dict(texts=mixed))
            assert len(grouped['embeddings'])==16
            individual=[worker.request(dict(texts=[t]))[0]['embeddings'][0] for t in mixed]
            delta=max(abs(x-y) for x,y in zip(sum(grouped['embeddings'],[]),sum(individual,[])))
            assert delta<.001,delta
            result[label]['mixed_split_component_error']=delta
            checkpoint()
        finally:worker.close()
    # Measure a single 32KiB prefetch against serial extraction+encoding; at most one future is live.
    with tempfile.TemporaryDirectory(prefix='semantic-prefetch-') as temp:
        folder=Path(temp).resolve();file=folder/'geology.txt';file.write_text((text+'\n')*400)
        scope=dict(roots=[str(folder)],excludedPaths=[],excludedFolderNames=[],excludedExtensions=[],includeHidden=False,blocked=[])
        extraction=Worker([a.file_worker.resolve(),'file-index-worker'])
        encoding=Worker([a.after.resolve(),a.model.resolve()])
        prefetch=[]
        try:
            encoding.request(dict(texts=texts[:4]))
            extraction.request(dict(operation='content',path=str(file),scope=scope,blocked=[],readText=True,cursor=dict(page=0,offset=0)))
            for overlap in [False,True]:
                with ThreadPoolExecutor(max_workers=1) as pool:
                    for n in range(100):
                        start=time.monotonic()
                        request=dict(operation='content',path=str(file),scope=scope,blocked=[],readText=True,cursor=dict(page=0,offset=(n%10)*32768))
                        if overlap:
                            future=pool.submit(extraction.request,request)
                            reply,encode_ms=encoding.request(dict(texts=texts[:4]))
                            read,read_ms=future.result()
                        else:
                            read,read_ms=extraction.request(request)
                            reply,encode_ms=encoding.request(dict(texts=texts[:4]))
                        assert not read.get('error') and read.get('pages'), read
                        assert sum(len(p['text'].encode()) for p in read['pages'])<=32768
                        prefetch.append(dict(overlap=overlap,round=n,total_ms=(time.monotonic()-start)*1000,read_ms=read_ms,encode_ms=encode_ms))
                        result['prefetch']=dict(rows=prefetch,max_inflight=1,max_extract_bytes=32768)
                        checkpoint()
        finally:extraction.close();encoding.close()
    result['prefetch']=dict(rows=prefetch,max_inflight=1,max_extract_bytes=32768)
    result['model_sha256']=hashlib.sha256(a.model.read_bytes()).hexdigest()
    result['scope']='Release helper IPC and one bounded next-text-batch extraction. No query/UI or voice measurement here.'
    (here/'batch-prefetch.json').write_text(json.dumps(result,indent=2)+'\n')
    print('Saved batch and prefetch comparison')

if __name__=='__main__':main()
