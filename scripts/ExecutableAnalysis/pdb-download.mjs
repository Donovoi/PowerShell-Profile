// Exact Microsoft symbol-store requests only; no target execution or remote symbol-path expansion.
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
const origin='https://msdl.microsoft.com/download/symbols/';
const publicUrl=value=>{const url=new URL(value);url.search='';url.hash='';return url.href;};
export function admitSymbolUrl(value){
  const url=new URL(value);
  if(url.protocol!=='https:'||url.username||url.password||url.port||url.hash||!(url.hostname==='msdl.microsoft.com'||/^[a-z0-9-]+\.blob\.core\.windows\.net$/.test(url.hostname)))throw new Error('Symbol redirect is outside the admitted HTTPS Microsoft endpoints.');
  return url.href;
}
export function admitSymbolProxy(value){
  if(!value)return null;
  const url=new URL(value);
  if(!['http:','https:','socks5h:'].includes(url.protocol)||!url.hostname||url.username||url.password||url.search||url.hash||(url.pathname&&url.pathname!=='/'))throw new Error('Symbol proxy must be an HTTP(S) or remote-DNS SOCKS5 endpoint without credentials or a path.');
  return url.href;
}
export async function curlSymbolRequest(url,options,spawnProcess=spawn){
  admitSymbolUrl(url);
  const args=['--disable','--silent','--show-error','--proto','=https','--max-redirs','0','--connect-timeout',String(Math.min(15,options.timeoutSeconds)),'--max-time',String(options.timeoutSeconds),'--max-filesize',String(options.maxBytes),'--dump-header',options.headerPath,'--output','-'];
  const proxy=admitSymbolProxy(options.proxy);if(proxy)args.push('--proxy',proxy);
  args.push('--url',url);
  const response=await new Promise((resolve,reject)=>{
    const child=spawnProcess(options.curlPath||'curl',args,{shell:false,windowsHide:true,stdio:['ignore','pipe','pipe']});
    const chunks=[];let bytes=0,errorText='',failure=null;
    const timer=setTimeout(()=>{failure=new Error('Symbol download exceeded its total time budget.');child.kill();},options.timeoutSeconds*1000+1000);
    child.stdout.on('data',chunk=>{bytes+=chunk.length;if(bytes>options.maxBytes){failure=new Error('Symbol response exceeded its byte budget.');child.kill();}else if(!failure)chunks.push(chunk);});
    child.stderr.on('data',chunk=>{if(errorText.length<4096)errorText+=chunk.toString('utf8').slice(0,4096-errorText.length);});
    child.on('error',error=>{failure=error;});
    child.on('close',code=>{clearTimeout(timer);if(failure)return reject(failure);if(code!==0)return reject(new Error('HTTPS symbol request failed (curl '+code+'): '+errorText.slice(0,1024)));resolve(Buffer.concat(chunks));});
  });
  const stat=await fs.stat(options.headerPath);if(stat.size>65536)throw new Error('Symbol response headers exceed their bound.');
  const raw=await fs.readFile(options.headerPath,'utf8');
  const blocks=raw.split(/\r?\n\r?\n/).filter(x=>/^HTTP\/\S+ \d{3}/.test(x));
  const lines=blocks.at(-1)?.split(/\r?\n/);if(!lines)throw new Error('Symbol response has no HTTP status.');
  const status=Number(lines[0].match(/^HTTP\/\S+ (\d{3})/)[1]);
  const locations=lines.slice(1).filter(x=>/^location:/i.test(x)).map(x=>x.slice(x.indexOf(':')+1).trim());
  if(locations.length>1)throw new Error('Symbol response has ambiguous redirect locations.');
  return {status,location:locations[0]??null,bytes:response};
}
export async function downloadSymbol(reference,config,request=curlSymbolRequest){
  const timeout=config.downloadTimeoutSeconds??90,maxBytes=config.maxPdbBytes??268435456;
  if(!Number.isInteger(timeout)||timeout<1||timeout>180||!Number.isSafeInteger(maxBytes)||maxBytes<1||maxBytes>1073741824)throw new Error('Invalid symbol download budget.');
  const receipt={Attempted:false,Status:config.allowDownload===false?'Disabled':'NotStarted',Source:'MicrosoftPublicSymbolServer',RequestUrl:origin+encodeURIComponent(reference.Name)+'/'+reference.SymbolKey+'/'+encodeURIComponent(reference.Name),Redirects:[],MaxBytes:maxBytes,TimeoutSeconds:timeout,TlsVerification:true};
  if(config.allowDownload===false)return {receipt,bytes:null};
  const directory=await fs.mkdtemp(path.join(config.outputDirectory,'pdb-download-'));
  const started=Date.now();
  try{
    const proxy=admitSymbolProxy(config.proxy);
    let url=admitSymbolUrl(receipt.RequestUrl),totalBytes=0;
    receipt.Attempted=true;receipt.StartedUtc=new Date().toISOString();
    for(let redirect=0;redirect<=3;redirect++){
      const remaining=Math.ceil(timeout-(Date.now()-started)/1000);if(remaining<=0)throw new Error('Symbol download exceeded its total time budget.');
      const response=await request(url,{curlPath:config.curlPath,proxy,timeoutSeconds:remaining,maxBytes:maxBytes-totalBytes,headerPath:path.join(directory,'headers-'+redirect)});
      if(Date.now()-started>timeout*1000)throw new Error('Symbol download exceeded its total time budget.');
      if(!Buffer.isBuffer(response.bytes))throw new Error('Symbol response did not supply bounded bytes.');
      totalBytes+=response.bytes.length;if(totalBytes>maxBytes)throw new Error('Symbol responses exceeded their total byte budget.');
      receipt.HttpStatus=response.status;receipt.TransferredBytes=totalBytes;
      if([301,302,303,307,308].includes(response.status)){
        if(redirect===3||!response.location)throw new Error('Symbol redirect count or location is invalid.');
        const next=admitSymbolUrl(new URL(response.location,url).href);receipt.Redirects.push({From:publicUrl(url),To:publicUrl(next),Status:response.status});url=next;continue;
      }
      receipt.FinalUrl=publicUrl(url);
      if(response.status!==200){receipt.Status=response.status===404?'NotFound':'HttpError';receipt.Error='Microsoft symbol request returned HTTP '+response.status+'.';return {receipt,bytes:null};}
      receipt.Status='Received';receipt.Bytes=response.bytes.length;return {receipt,bytes:response.bytes};
    }
  }catch(error){receipt.Status='Failed';receipt.Error=String(error.message).replace(/https?:\/\/\S+/g,'[endpoint]').slice(0,2048);return {receipt,bytes:null};}
  finally{receipt.ElapsedMilliseconds=Date.now()-started;for(let i=0;i<=3;i++)await fs.rm(path.join(directory,'headers-'+i),{force:true});await fs.rmdir(directory);}
}
async function localDirectory(selected){
  if(!path.isAbsolute(selected)||/^[/\\]{2}/.test(selected))throw new Error('Symbol cache must be an absolute local directory.');
  const full=path.resolve(selected),parts=[];
  for(let item=full;;item=path.dirname(item)){parts.unshift(item);if(path.dirname(item)===item)break;}
  for(const item of parts){let stat;try{stat=await fs.lstat(item);}catch(error){if(error.code!=='ENOENT')throw error;try{await fs.mkdir(item);}catch(mkdirError){if(mkdirError.code!=='EEXIST')throw mkdirError;}stat=await fs.lstat(item);}if(!stat.isDirectory()||stat.isSymbolicLink())throw new Error('Symbol cache contains a non-directory or reparse path.');}
  return full;
}
export async function cacheSymbol(bytes,reference,cacheDirectory){
  const root=await localDirectory(cacheDirectory);
  const directory=await localDirectory(path.join(root,reference.Name,reference.SymbolKey));
  const destination=path.join(directory,reference.Name),temporary=path.join(directory,'.download-'+randomUUID()+'.tmp');
  try{await fs.writeFile(temporary,bytes,{flag:'wx'});await fs.link(temporary,destination);return destination;}
  finally{await fs.rm(temporary,{force:true});}
}
