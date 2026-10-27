// Match local RSDS/MSF7 companions by identity, never by filename alone. No network or target execution.
import fs from 'node:fs/promises';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const guid=bytes=>[bytes.readUInt32LE(0).toString(16).padStart(8,'0'),bytes.readUInt16LE(4).toString(16).padStart(4,'0'),bytes.readUInt16LE(6).toString(16).padStart(4,'0'),bytes.subarray(8,10).toString('hex'),bytes.subarray(10,16).toString('hex')].join('-');
const range=(offset,length,size)=>{if(!Number.isSafeInteger(offset)||!Number.isSafeInteger(length)||offset<0||length<0||offset+length>size)throw new Error('Binary range exceeds its bounded file.');};
export async function inspectPeDebug(read,size){
  const dos=await read(0,64);if(dos.toString('ascii',0,2)!=='MZ')return null;
  const pe=dos.readUInt32LE(60);if(pe>16777216)throw new Error('PE header exceeds the inspection bound.');
  const coff=await read(pe,24);if(coff.readUInt32LE(0)!==0x4550)throw new Error('Invalid PE signature.');
  const count=coff.readUInt16LE(6),optionalSize=coff.readUInt16LE(20);
  if(count>96||optionalSize>4096)throw new Error('PE section or optional-header bound exceeded.');
  if(optionalSize<2)return null;
  const headers=await read(pe+24,optionalSize+count*40),magic=headers.readUInt16LE(0);
  const directories=magic===0x20b?112:magic===0x10b?96:null;
  if(directories===null||optionalSize<directories+7*8)return null;
  const map=(rva,length)=>{
    const candidates=[];
    if(rva+length<=headers.readUInt32LE(60))candidates.push(rva);
    for(let i=0;i<count;i++){const off=optionalSize+i*40,start=headers.readUInt32LE(off+12),rawSize=headers.readUInt32LE(off+16),delta=rva-start;if(delta>=0&&delta+length<=rawSize)candidates.push(headers.readUInt32LE(off+20)+delta);}
    if(candidates.length!==1)throw new Error('Debug RVA has no unique file mapping.');range(candidates[0],length,size);return candidates[0];
  };
  const rva=headers.readUInt32LE(directories+48),bytes=headers.readUInt32LE(directories+52);
  if(!rva||!bytes)return null;if(bytes%28||bytes>28*128)throw new Error('Debug directory exceeds its record bound.');
  const records=await read(map(rva,bytes),bytes),references=[];
  for(let off=0;off<bytes;off+=28){
    if(records.readUInt32LE(off+12)!==2)continue;
    const length=records.readUInt32LE(off+16),raw=records.readUInt32LE(off+24);
    if(length<24||length>4096)throw new Error('CodeView record exceeds its bound.');
    const data=await read(raw||map(records.readUInt32LE(off+20),length),length);
    if(data.toString('ascii',0,4)!=='RSDS')continue;
    const end=data.indexOf(0,24);if(end<0||end-24>512)throw new Error('PDB filename is not bounded and terminated.');
    const name=data.toString('utf8',24,end).split(/[\\/]/).at(-1);
    if(!name||!name.toLowerCase().endsWith('.pdb')||/[<>:"/\\|?*\x00-\x1f]/.test(name)||/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(name))throw new Error('Unsafe PDB basename.');
    const identity={Kind:'RSDS',Name:name,Guid:guid(data.subarray(4,20)),Age:data.readUInt32LE(20)};
    identity.SymbolKey=identity.Guid.replaceAll('-','').toUpperCase()+identity.Age.toString(16).toUpperCase();references.push(identity);
  }
  const unique=[...new Map(references.map(x=>[x.Guid+':'+x.Age+':'+x.Name.toLowerCase(),x])).values()];
  if(unique.length>1)throw new Error('Multiple distinct RSDS identities; automatic PDB selection is ambiguous.');
  return unique[0]??null;
}
export function inspectPdb(bytes){
  if(bytes.length<56||bytes.toString('ascii',0,32)!=='Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0')throw new Error('Unsupported PDB/MSF signature.');
  const block=bytes.readUInt32LE(32),blocks=bytes.readUInt32LE(40),directorySize=bytes.readUInt32LE(44),map=bytes.readUInt32LE(52);
  if(![512,1024,2048,4096,8192,16384,32768,65536].includes(block)||blocks*block>bytes.length||directorySize>1048576||directorySize<4)throw new Error('Invalid or oversized MSF directory.');
  const count=Math.ceil(directorySize/block);if(count*4>block)throw new Error('MSF block-map bound exceeded.');range(map*block,count*4,bytes.length);
  const pages=[];for(let i=0;i<count;i++){const index=bytes.readUInt32LE(map*block+i*4);if(index>=blocks)throw new Error('Invalid MSF directory page.');pages.push(bytes.subarray(index*block,(index+1)*block));}
  const directory=Buffer.concat(pages).subarray(0,directorySize),streams=directory.readUInt32LE(0);if(streams>65536)throw new Error('MSF stream bound exceeded.');range(4,streams*4,directory.length);
  let position=4+streams*4;const entries=[];
  for(let i=0;i<streams;i++){
    const size=directory.readUInt32LE(4+i*4),indices=[];if(size===0xffffffff){entries.push(null);continue;}
    const length=Math.ceil(size/block);range(position,length*4,directory.length);
    for(let j=0;j<length;j++){const index=directory.readUInt32LE(position);position+=4;if(index>=blocks)throw new Error('Invalid MSF stream page.');indices.push(index);}
    entries.push({size,indices});
  }
  const prefix=(index,length)=>{const stream=entries[index];if(!stream||stream.size<length)return null;const pieces=stream.indices.slice(0,Math.ceil(length/block)).map(n=>bytes.subarray(n*block,(n+1)*block));return Buffer.concat(pieces).subarray(0,length);};
  const info=prefix(1,28);if(!info)throw new Error('PDB identity stream is missing.');
  const tpi=prefix(2,20),dbi=prefix(3,64);
  const hasDbi=Boolean(dbi&&dbi.readUInt32LE(0)===0xffffffff);
  // Public-symbol stripping can advance the Info stream age. The DBI age is
  // the executable matching age when DBI is present (also used by Ghidra).
  return {Guid:guid(info.subarray(12,28)),Age:hasDbi?dbi.readUInt32LE(8):info.readUInt32LE(8),InfoAge:info.readUInt32LE(8),AgeSource:hasDbi?'DBI':'Info',TpiTypeRecords:tpi&&tpi.readUInt32LE(12)>=tpi.readUInt32LE(8)?tpi.readUInt32LE(12)-tpi.readUInt32LE(8):null,DbiStripped:hasDbi?Boolean(dbi.readUInt16LE(56)&2):null};
}
async function localFile(selected,maxBytes){
  const full=path.resolve(selected);if(/^[/\\]{2}/.test(selected))throw new Error('Network symbol paths are not admitted.');
  for(let part=full;;part=path.dirname(part)){if((await fs.lstat(part)).isSymbolicLink())throw new Error('Symbol reparse paths are refused.');if(path.dirname(part)===part)break;}
  const physical=await fs.realpath(full),handle=await fs.open(full,'r');
  try{const stat=await handle.stat();if(!stat.isFile()||stat.size>maxBytes)throw new Error('PDB file exceeds its byte budget or is not regular.');const bytes=await handle.readFile();const after=await handle.stat();if(stat.size!==after.size||stat.mtimeMs!==after.mtimeMs||bytes.length!==stat.size||physical!==await fs.realpath(full))throw new Error('PDB changed during inspection.');return bytes;}finally{await handle.close();}
}
export async function resolvePdb(config){
  const record={SchemaVersion:1,Status:'NotFound',Reference:null,Loaded:false,SearchComplete:true,CandidatesInspected:0,RejectedCandidates:[],Limitations:[]};
  const handle=await fs.open(config.inputPath,'r');
  try{const stat=await handle.stat();record.Reference=await inspectPeDebug(async(offset,length)=>{range(offset,length,stat.size);const bytes=Buffer.alloc(length);const result=await handle.read(bytes,0,length,offset);if(result.bytesRead!==length)throw new Error('PE changed during inspection.');return bytes;},stat.size);}finally{await handle.close();}
  if(!record.Reference){record.Status='NoRsdsReference';return record;}
  const roots=[...(config.searchPaths??[]),config.sourceDirectory,config.cacheDirectory,'C:\\Symbols'];
  for(const item of (config.symbolPath??'').split(';')){for(const part of item.split('*'))if(path.isAbsolute(part)&&!/^[/\\]{2}/.test(part))roots.push(part);}
  const candidates=[];const seen=new Set();
  for(const root of roots.filter(x=>typeof x==='string'&&x&&path.isAbsolute(x)&&!/^[/\\]{2}/.test(x))){
    const files=path.extname(root).toLowerCase()==='.pdb'?[root]:[path.join(root,record.Reference.Name),path.join(root,record.Reference.Name,record.Reference.SymbolKey,record.Reference.Name)];
    for(const file of files){const key=process.platform==='win32'?file.toLowerCase():file;if(!seen.has(key)){seen.add(key);candidates.push(file);}}
  }
  for(const file of candidates){
    if(record.CandidatesInspected>=128){record.SearchComplete=false;break;}
    try{
      try{if((await fs.lstat(file)).isDirectory())continue;}catch(error){if(error.code==='ENOENT'||error.code==='ENOTDIR')continue;throw error;}
      record.CandidatesInspected++;
      const bytes=await localFile(file,config.maxPdbBytes??268435456),identity=inspectPdb(bytes);
      if(identity.Guid!==record.Reference.Guid||identity.Age!==record.Reference.Age){record.RejectedCandidates.push({Path:file,Reason:'GUID/age mismatch'});continue;}
      const directory=path.join(config.outputDirectory,'symbols');await fs.mkdir(directory,{recursive:true});
      const retained=path.join(directory,record.Reference.Name);await fs.writeFile(retained,bytes,{flag:'wx'});
      if(sha(await fs.readFile(retained))!==sha(bytes))throw new Error('Retained PDB hash differs.');
      Object.assign(record,{Status:'Matched',SelectedPath:file,RetainedPath:retained,RelativePath:'symbols/'+record.Reference.Name,Bytes:bytes.length,SHA256:sha(bytes),Identity:identity});
      if(identity.TpiTypeRecords===0)record.Limitations.push('The matching PDB contains zero TPI type records; private structure layouts and local types are not supplied by that companion.');
      return record;
    }catch(error){if(record.RejectedCandidates.length<128)record.RejectedCandidates.push({Path:file,Reason:error.message});}
  }
  record.Limitations.push('This input references '+record.Reference.Name+' ('+record.Reference.Guid+', age '+record.Reference.Age+'), but no matching available local PDB was retained.');
  return record;
}
if(process.argv[1]&&pathToFileURL(path.resolve(process.argv[1])).href===import.meta.url){
  const configPath=process.argv[2];const data=await fs.readFile(configPath);if(data.length>65536)throw new Error('PDB configuration exceeds its bound.');
  const config=JSON.parse(data),record=await resolvePdb(config);
  await fs.writeFile(path.join(config.outputDirectory,'basic/pdb-context.json'),JSON.stringify(record,null,2),{flag:'wx'});
  process.stdout.write(JSON.stringify({Status:record.Status,Reference:record.Reference,RelativePath:record.RelativePath??null})+'\n');
}
