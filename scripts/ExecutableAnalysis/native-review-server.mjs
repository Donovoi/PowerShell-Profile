// Forward only static REA queries, pinned to the one preserved input and hash.
import fs from 'node:fs/promises';
import path from 'node:path';
import readline from 'node:readline';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';

const [reaScript,selectedInputArgument,expectedHash,ghidra]=process.argv.slice(2);
if(!path.isAbsolute(reaScript??'')||!path.isAbsolute(selectedInputArgument??'')||!/^[a-f0-9]{64}$/i.test(expectedHash??''))throw new Error('Trusted REA script, preserved input and SHA256 are required.');
const selectedInput=path.resolve(selectedInputArgument);
// Windows short names and directory aliases can legitimately resolve to a
// different spelling. Pin the physical target once, then recheck it and its hash.
const input=await fs.realpath(selectedInput);
const samePath=(a,b)=>process.platform==='win32'?a.toLowerCase()===b.toLowerCase():a===b;
const allowed=new Set(['binary_session','open_binary','binary_overview','list_procedures','list_strings','procedure_pseudo_code','read_function_instructions','read_bytes','xrefs','resolve_containing_procedure','resolve_native_call_targets','trace_call_path','trace_native_values','close_binary']);
const pending=new Map();
const child=spawn(process.execPath,[reaScript,'--mcp'],{cwd:path.dirname(input),windowsHide:true,shell:false,stdio:['pipe','pipe','pipe'],env:{...process.env,...(ghidra?{GHIDRA_INSTALL_DIR:ghidra}:{})}});
const send=(id,result)=>process.stdout.write(JSON.stringify({jsonrpc:'2.0',id,result})+'\n');
let stderrBytes=0,closing=false;
child.stderr.on('data',data=>{if(stderrBytes<65536){const part=data.subarray(0,65536-stderrBytes);process.stderr.write(part);stderrBytes+=part.length;}});
child.on('error',error=>{process.stderr.write(error.message+'\n');process.exitCode=1;});
async function validateInput(){
  const info=await fs.lstat(selectedInput);if(!info.isFile()||info.isSymbolicLink()||info.size>536870912)throw new Error('Preserved input is not a bounded regular file.');
  const real=await fs.realpath(selectedInput);if(!samePath(real,input))throw new Error('Preserved input path changed.');
  if(createHash('sha256').update(await fs.readFile(input)).digest('hex')!==expectedHash.toLowerCase())throw new Error('Preserved input hash changed; native opening was refused.');
}
const replies=(async()=>{
  for await(const line of readline.createInterface({input:child.stdout,crlfDelay:Infinity})){
    if(Buffer.byteLength(line)>4194304){process.stderr.write('Native response exceeded 4 MiB; no truncated evidence was admitted.\n');child.kill();process.exitCode=1;break;}
    let message;try{message=JSON.parse(line);}catch{process.stderr.write('Invalid native protocol response.\n');child.kill();process.exitCode=1;break;}
    const method=pending.get(message.id);pending.delete(message.id);
    if(message.id==='__review_cleanup__')continue;
    if(method==='tools/list'&&message.result?.tools)message.result.tools=message.result.tools.filter(tool=>allowed.has(tool.name));
    process.stdout.write(JSON.stringify(message)+'\n');
  }
})();
try{
  for await(const line of readline.createInterface({input:process.stdin,crlfDelay:Infinity})){
    if(Buffer.byteLength(line)>65536)throw new Error('Native request exceeds 64 KiB.');
    let request;try{request=JSON.parse(line);}catch{continue;}
    if(request.method==='tools/call'){
      const name=request.params?.name;
      try{
        if(!allowed.has(name))throw new Error('Only the scoped static native tools are available.');
        if(name==='open_binary'){
          const arguments_=request.params.arguments??{};
          if(arguments_.path&&!samePath(path.resolve(arguments_.path),selectedInput)&&!samePath(path.resolve(arguments_.path),input))throw new Error('Native queries are pinned to the selected preserved input.');
          if(arguments_.provider_id&&arguments_.provider_id!=='ghidra')throw new Error('Native provider is pinned to Ghidra.');
          await validateInput();request.params.arguments={path:input,provider_id:'ghidra'};
        }
      }catch(error){send(request.id,{isError:true,content:[{type:'text',text:error.message}]});continue;}
    }else if(!['initialize','tools/list','ping','notifications/initialized','notifications/cancelled'].includes(request.method)){
      if(request.id!==undefined)process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,error:{code:-32601,message:'Method not available in static review.'}})+'\n');continue;
    }
    if(request.id!==undefined)pending.set(request.id,request.method);
    child.stdin.write(JSON.stringify(request)+'\n');
  }
}finally{
  closing=true;
  if(!child.killed&&!child.stdin.destroyed){child.stdin.write(JSON.stringify({jsonrpc:'2.0',id:'__review_cleanup__',method:'tools/call',params:{name:'close_binary',arguments:{}}})+'\n');child.stdin.end();}
  const timer=setTimeout(()=>child.kill(),5000);timer.unref();await replies;clearTimeout(timer);
}
child.on('exit',code=>{if(code&&!closing)process.exitCode=code;});
