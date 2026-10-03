import Foundation

extension AskBrowserExecutor {
    static func actionScript(id: String, command: String) -> String {
        """
        (()=>{const state=window.__typefluxObservation;
        if(!state||state.id!==\(AskLocalTools.javascriptLiteral(id)))return JSON.stringify({status:'invalid',message:'needs-observation',event_dispatched:false,effect_verified:false});
        return state.run(\(command));})()
        """
    }

    static func observationScript(id: String, read: Bool) -> String {
        "(()=>{const observationID=" + AskLocalTools
            .javascriptLiteral(id) + ";const includeText=" + String(read) + ";" + observationBody + "})()"
    }

    /// Keep element objects in a closure rather than trusting editable DOM ref
    /// attributes. Mutation records are drained synchronously before acting.
    /// AppleScript has no isolated JS world: this is NOT hostile-page attestation.
    static let observationBody = #"""
    if(window.__typefluxObservation&&typeof window.__typefluxObservation.dispose==='function')window.__typefluxObservation.dispose();
    const doc=document,url=location.href,generation=String(performance.timeOrigin);
    const viewport=[innerWidth,innerHeight,scrollX,scrollY].join(':');
    const rect=e=>{const r=e.getBoundingClientRect();return [r.x,r.y,r.width,r.height].join(':')};
    const visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'};
    const nodes=[...document.querySelectorAll('a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[contenteditable]')].filter(visible).slice(0,200);
    const rects=nodes.map(rect);
    let dirty=false,used=false;
    const observer=new MutationObserver(()=>{dirty=true});
    observer.observe(document,{subtree:true,childList:true,attributes:true,characterData:true});
    const invalidate=()=>{dirty=true};
    const windowEvents=['blur','pagehide','popstate','hashchange'];
    windowEvents.forEach(name=>window.addEventListener(name,invalidate));
    document.addEventListener('visibilitychange',invalidate);
    const dispose=()=>{observer.disconnect();windowEvents.forEach(name=>window.removeEventListener(name,invalidate));document.removeEventListener('visibilitychange',invalidate)};
    const response=(status,message,sent=false,verified=false)=>JSON.stringify({status,message,event_dispatched:sent,effect_verified:verified});
    const stale=()=>dirty||observer.takeRecords().length>0||document!==doc||location.href!==url||String(performance.timeOrigin)!==generation||[innerWidth,innerHeight,scrollX,scrollY].join(':')!==viewport;
    window.__typefluxObservation={id:observationID,dispose,run:command=>{
        if(used||stale())return response('invalid','needs-observation');
        used=true;dispose();
        let sent=false;
        try{
            if(command.action==='open'){sent=true;location.href=command.url;return response('ok','Navigation requested; destination and business effect are unverified.',true)}
            if(command.action==='back'){sent=true;history.back();return response('ok','Back requested; destination and business effect are unverified.',true)}
            if(command.action==='scroll'){sent=true;window.scrollBy(0,command.amount*Math.round(innerHeight*0.8));return response('ok','Scroll requested; observe again.',true)}
            let e;
            if(command.ref){
                const prefix=observationID+':';
                if(!command.ref.startsWith(prefix))return response('invalid','needs-observation');
                const index=Number(command.ref.slice(prefix.length));
                if(!Number.isInteger(index)||index<1)return response('invalid','Element not found');
                e=nodes[index-1];
            }else{e=document.querySelector(command.selector)}
            if(!e)return response('invalid','Element not found');
            const index=nodes.indexOf(e);
            if(index<0||!e.isConnected||e.ownerDocument!==doc||!visible(e)||rect(e)!==rects[index])return response('invalid','needs-observation');
            if(e.disabled||e.readOnly||e.getAttribute('aria-disabled')==='true')return response('invalid','Element is disabled or read-only');
            if(command.action==='click'){sent=true;e.click();return response('ok','Click dispatched; business effect is unverified.',true)}
            if(command.action!=='fill')return response('invalid','Unsupported action');
            let getter;
            if(e instanceof HTMLTextAreaElement||(e instanceof HTMLInputElement&&['text','search','url','tel','email','password','number'].includes(e.type))){
                const prototype=e instanceof HTMLTextAreaElement?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
                const descriptor=Object.getOwnPropertyDescriptor(prototype,'value');
                sent=true;descriptor.set.call(e,command.text);getter=()=>descriptor.get.call(e);
            }else if(e.isContentEditable){sent=true;e.textContent=command.text;getter=()=>e.textContent}
            else{return response('invalid','Element does not support fill')}
            e.dispatchEvent(new InputEvent('input',{bubbles:true,composed:true,inputType:'insertText',data:command.text}));
            e.dispatchEvent(new Event('change',{bubbles:true}));
            const verified=e.isConnected&&getter()===command.text;
            return response('ok',verified?'Input/change dispatched and immediate field value verified; submission and persistence are unverified.':'Input/change dispatched; field value was not verified.',true,verified);
        }catch(error){return response(sent?'unknown':'invalid',sent?'Action result unknown; observe and reconcile.':'Invalid selector or action',sent)}
    }};
    return JSON.stringify({observation_id:observationID,url,title:document.title,
        text:includeText?(document.body?document.body.innerText.slice(0,30000):''):undefined,
        elements:nodes.map((e,i)=>({ref:observationID+':'+(i+1),tag:e.tagName.toLowerCase(),role:e.getAttribute('role')||e.type||'',
            name:(e.getAttribute('aria-label')||e.innerText||e.getAttribute('placeholder')||e.title||e.getAttribute('href')||'').trim().replace(/\s+/g,' ').slice(0,100)}))});
    """#
}
