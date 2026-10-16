#!/usr/bin/env python3
"""Fixed synthetic oracle calibration. Never reads user files; held-out topics stay out of selection."""
import argparse, json, math, re, select, subprocess, time, unicodedata
from pathlib import Path


def normalized(text):
    return ''.join(c for c in unicodedata.normalize('NFKD', unicodedata.normalize('NFKC', text)).casefold()
                   if not unicodedata.combining(c))


def terms(text):
    words, word, previous = [], '', ''
    for c in normalized(text):
        cjk = ('\u3400' <= c <= '\u9fff' or '\u3040' <= c <= '\u30ff' or '\uac00' <= c <= '\ud7af')
        if cjk:
            if word: words.append(word); word = ''
            words.append(c)
            if previous: words.append(previous + c)
            previous = c
        else:
            previous = ''
            if c.isalnum(): word += c
            elif word: words.append(word); word = ''
    if word: words.append(word)
    return set(words)

STOP = {'the','a','an','is','are','of','to','for','in','and','how','what'}


def features(query, document):
    ts = terms(query) - STOP
    ts = {t for t in ts if not (len(t) == 1 and '\u3400' <= t <= '\u9fff')}
    coverage = len(ts & terms(document)) / len(ts) if ts else 0
    ids = [t for t in normalized(query).split() if any(c.isdigit() for c in t)
           and ('-' in t or '_' in t or (len(t) >= 4 and t.isdigit()))]
    exact = bool(ids) and all(re.search(r'(?<![\w-])' + re.escape(t) + r'(?![\w-])',normalized(document)) for t in ids)
    return coverage, normalized(query) in normalized(document), bool(ids), exact


def evaluate(data, floor, fusion, split, absolute=.65, margin=.08):
    rows=[]
    for query in data['queries']:
        topic=int(query['id'].rsplit('-',1)[1])
        if ('train' if topic % 2 == 0 else 'holdout') != split: continue
        candidates=[]
        for i, document in enumerate(data['documents']):
            cosine = sum(a*b for a,b in zip(data['vectors'][i],data['query_vectors'][query['id']]))
            coverage, phrase, identifier, exact = features(query['query'],document['text'])
            if identifier and not exact: continue
            lexical = coverage >= .5
            if not lexical and cosine < floor: continue
            if not lexical: coverage=0; phrase=False
            lscore=.3*coverage**2 + .12*phrase + .35*(coverage==1) - .18*(0 < coverage < 1)
            score=1+.01*cosine if exact else .55*max(0,cosine)+lscore
            candidates.append(dict(id=document['id'],cosine=cosine,lexical=lscore,accepted=lexical,complete=coverage==1,score=score))
        peaks=sorted([r['cosine'] for r in candidates],reverse=True)
        confident = any(r['complete'] for r in candidates) or (peaks and peaks[0] >= absolute) or (len(peaks)>1 and peaks[0]-peaks[1]>=margin)
        if not confident:
            candidates=[r for r in candidates if r['accepted']]
        if fusion == 'rrf':
            vr={r['id']:i+1 for i,r in enumerate(sorted(candidates,key=lambda r:-r['cosine']))}
            lr={r['id']:i+1 for i,r in enumerate(sorted((r for r in candidates if r['lexical'] > 0),key=lambda r:-r['lexical']))}
            for r in candidates: r['score']=1/(60+vr[r['id']])+(1/(60+lr[r['id']]) if r['id'] in lr else 0)
        candidates.sort(key=lambda r:(-r['score'],r['id']))
        hits=[r['id'] for r in candidates[:5]]
        rank=next((i+1 for i,k in enumerate(hits) if k in query['expected']),None)
        rows.append(dict(id=query['id'],group=query['group'],supported=query['group'] not in ['scanned','media_timestamp'],
                         answerable=bool(query['expected']),rank=rank,hits=hits))
    groups={}
    for g in sorted({r['group'] for r in rows}):
        rs=[r for r in rows if r['group']==g]
        groups[g]=dict(n=len(rs),recall_at_5=sum(r['rank'] is not None for r in rs)/len(rs),
                       mrr=sum(1/r['rank'] if r['rank'] else 0 for r in rs)/len(rs),
                       false_positive_rate=sum(bool(r['hits']) for r in rs)/len(rs) if g=='no_answer' else None)
    supported=[r for r in rows if r['supported'] and r['answerable']]
    no_answer=[r for r in rows if not r['answerable']]
    return dict(groups=groups,rows=rows,supported_recall=sum(r['rank'] is not None for r in supported)/len(supported),
                supported_mrr=sum(1/r['rank'] if r['rank'] else 0 for r in supported)/len(supported),
                false_positive_rate=sum(bool(r['hits']) for r in no_answer)/len(no_answer))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--helper',type=Path,required=True);p.add_argument('--model',type=Path,required=True)
    p.add_argument('--capture-only',action='store_true')
    args=p.parse_args()
    root=Path(__file__).resolve().parents[5]
    here=Path(__file__).parent
    target=here/'raw-quality-vectors.json'
    fixture=json.loads((here.parent/'queries.json').read_text())
    if not target.exists():
        docs=[d for d in fixture['documents'] if d['kind'] in ['text','long_tail']]
        process=subprocess.Popen([str(args.helper.resolve()),str(args.model.resolve())],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
        def embed(texts):
            process.stdin.write(json.dumps(dict(texts=texts))+'\n');process.stdin.flush()
            if not select.select([process.stdout],[],[],120)[0]: raise TimeoutError('embedding')
            reply=json.loads(process.stdout.readline())
            if 'error' in reply: raise ValueError(reply)
            return reply['embeddings']
        try:
            vectors=[]
            for d in docs: vectors.extend(embed(['title: '+d['id']+'.txt | text: '+d['text']]))
            qvectors={q['id']:embed(['task: search result | query: '+q['query']])[0] for q in fixture['queries']}
            probe=embed(['task: search result | query: How can I get back money spent during business travel native false hot-new-semantic 0',
                         'title: handbook.txt | text: Employees submit project expense reimbursement requests using the finance form. Attach receipts and obtain manager approval.'])
            target.write_text(json.dumps(dict(documents=docs,queries=fixture['queries'],vectors=vectors,query_vectors=qvectors,
                native_probe_cosine=sum(a*b for a,b in zip(*probe)),model_sha256='2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135'))+'\n')
        finally:
            process.stdin.close()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill();process.wait()
            process.stdout.close()
    data=json.loads(target.read_text())
    trials=[]
    for fusion in ['calibrated','rrf']:
        for floor in [.45,.5,.55]:
            train=evaluate(data,floor,fusion,'train')
            trials.append(dict(floor=floor,fusion=fusion,**{k:v for k,v in train.items() if k!='rows'}))
    eligible=[r for r in trials if r['false_positive_rate'] <= .05]
    selected=max(eligible,key=lambda r:(r['supported_recall'],r['supported_mrr'],-r['floor'],r['fusion']=='calibrated'))
    final=evaluate(data,selected['floor'],selected['fusion'],'holdout')
    report=dict(split='Even topic IDs train, odd topic IDs held out. All 200 queries frozen before selection; unsupported groups remain failures.',
        candidates=trials,selected=selected,holdout=final,native_probe_cosine=data['native_probe_cosine'],
        limitation='Hand-authored single-source synthetic regression oracle. Text/long-tail documents only. No media embeddings or scanned PDFs in this harness; no representative relevance claim.')
    (here/'calibration.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['candidates','holdout']},indent=2))

if __name__=='__main__':main()
