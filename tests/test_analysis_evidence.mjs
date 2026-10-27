import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { EvidenceStore, toolCatalog } from '../scripts/ExecutableAnalysis/evidence-server.mjs';

let root,store;
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
beforeEach(async()=>{
  root=await fs.mkdtemp(path.join(os.tmpdir(),'analysis-evidence-'));
  for(const dir of ['rea/rea-code','rea/rea-raw','basic','input'])await fs.mkdir(path.join(root,dir),{recursive:true});
  const bodies=['int entry(void) { return target(); }\n','int target(void) { return 42; }\n'];
  const artifacts=[];
  for(let i=0;i<2;i++){const relative=`rea-code/00000${i+1}-0x${(0x140001000+i*16).toString(16)}.c`;await fs.writeFile(path.join(root,'rea',relative),bodies[i]);artifacts.push({Path:relative,Kind:'decompiled-pseudocode',Bytes:Buffer.byteLength(bodies[i]),SHA256:sha(bodies[i])});}
  await fs.writeFile(path.join(root,'rea/rea-raw/procedures.json'),JSON.stringify({structuredContent:{normalized_result:[{address:'0x140001000',value:'entry'},{address:'0x140001010',value:'target'}]}}));
  await fs.writeFile(path.join(root,'rea/rea-result.json'),JSON.stringify({Status:'Succeeded',Coverage:{DecompiledFunctions:2,ExternalFunctions:3,Complete:true},Stages:[{Tool:'list_procedures',EvidencePath:'rea-raw/procedures.json'}],Artifacts:artifacts}));
  await fs.writeFile(path.join(root,'basic/identity.json'),JSON.stringify({Format:'PE',Architecture:'x86_64'}));
  const pe=Buffer.alloc(1024);pe.write('MZ');pe.writeUInt32LE(0x80,0x3c);pe.writeUInt32LE(0x4550,0x80);pe.writeUInt16LE(1,0x86);pe.writeUInt16LE(0xf0,0x94);pe.writeUInt16LE(0x20b,0x98);pe.writeBigUInt64LE(0x140000000n,0xb0);pe.writeUInt32LE(0x200,0xd4);pe.writeUInt32LE(0x1000,0x194);pe.writeUInt32LE(0x200,0x198);pe.writeUInt32LE(0x200,0x19c);pe[0x210]=0x42;
  await fs.writeFile(path.join(root,'input/inert.exe'),pe);
  store=await EvidenceStore.create(root);
});
afterEach(async()=>{if(root)await fs.rm(root,{recursive:true,force:true});});

test('function index includes exact names, addresses, provider source and paged bodies',async()=>{
  const summary=await store.call('analysis_summary');assert.equal(summary.recovered_functions,2);assert.equal(summary.providers[0].path,'rea/rea-result.json');
  const found=await store.call('list_functions',{query:'entry',limit:1});assert.equal(found.functions[0].address,'0x140001000');
  let offset=0,text='';do{const page=await store.call('read_function',{query:'entry',offset,limit:7});text+=page.text;offset=page.next_offset;}while(offset!==null);
  assert.equal(text,'int entry(void) { return target(); }\n');
});
test('oversized text reads return bounded complete pages for evidence and functions',async()=>{
  const code='// paged evidence: 😀 " \\\n'.repeat(16000);
  const manifestPath=path.join(root,'rea/rea-result.json');
  const manifest=JSON.parse(await fs.readFile(manifestPath,'utf8'));
  await fs.writeFile(path.join(root,store.bodies[0].path),code);
  Object.assign(manifest.Artifacts[0],{Bytes:Buffer.byteLength(code),SHA256:sha(code)});
  manifest.Padding=code;
  const evidence=JSON.stringify(manifest);
  await fs.writeFile(manifestPath,evidence);
  store=await EvidenceStore.create(root);
  for(const [name,args,expected]of [['read_function',{query:'entry'},code],['read_evidence',{path:'rea/rea-result.json'},evidence]]){
    const schema=toolCatalog.find(x=>x.name===name).inputSchema.properties.limit;
    assert.equal(schema.minimum,1);assert.ok(schema.maximum>=250000);
    const initial=await store.call(name,args);assert.equal(initial.text,expected.slice(0,20000));assert.equal(initial.limit_clamped,false);
    for(const requested of [13,24000,25000,250000,Number.MAX_SAFE_INTEGER]){
      const page=await store.call(name,{...args,offset:17,limit:requested});
      const applied=Math.min(requested,24000);
      assert.equal(page.text,expected.slice(17,17+applied));assert.equal(page.next_offset,17+applied);
      assert.equal(page.requested_limit,requested);assert.equal(page.applied_limit,applied);
      assert.equal(page.returned_characters,applied);assert.equal(page.page_limit,24000);assert.equal(page.limit_clamped,requested>24000);
    }
    let offset=0,reconstructed='';
    do{
      const page=await store.call(name,{...args,offset,limit:250000});
      assert.equal(page.sha256,sha(expected));assert.equal(page.characters,expected.length);
      assert.ok(page.text.length<=24000);assert.equal(page.returned_characters,page.text.length);
      assert.ok(page.next_offset===null||page.next_offset>offset);
      reconstructed+=page.text;offset=page.next_offset;
    }while(offset!==null);
    assert.equal(reconstructed,expected);
    const eof=await store.call(name,{...args,offset:expected.length,limit:250000});
    assert.equal(eof.text,'');assert.equal(eof.returned_characters,0);assert.equal(eof.next_offset,null);
  }
});
test('text pagination still rejects invalid sizes and preserves the file read budget',async()=>{
  for(const name of ['read_evidence','read_function']){
    const args=name==='read_evidence'?{path:'basic/identity.json'}:{query:'entry'};
    for(const limit of [0,-1,1.5,'250000',null,Number.MAX_SAFE_INTEGER+1])await assert.rejects(store.call(name,{...args,limit}),/Invalid bounded integer: limit/);
    await assert.rejects(store.call(name,{...args,offset:16777217,limit:250000}),/Invalid bounded integer: offset/);
  }
  const large=path.join(root,'basic/too-large.txt');await fs.writeFile(large,'');await fs.truncate(large,16777217);
  store=await EvidenceStore.create(root);
  await assert.rejects(store.call('read_evidence',{path:'basic/too-large.txt',limit:250000}),/read budget/);
  await assert.rejects(store.call('read_evidence',{path:'../outside.txt',limit:250000}),/retained|contained/);
});
test('retention audit independently catches tampered, missing and forged-path bodies',async()=>{
  assert.equal((await store.call('audit_decompilation')).complete,true);
  await fs.appendFile(path.join(root,store.bodies[0].path),'tampered');await fs.unlink(path.join(root,store.bodies[1].path));
  const result=await store.call('audit_decompilation');assert.equal(result.failure_count,2);assert.equal(result.complete,false);
  store.bodies[0].path='../outside.txt';assert.match((await store.call('audit_decompilation')).failures[0].error,/contained/);
});
test('direct Ghidra function manifests map code paths and canonical addresses',async()=>{
  await fs.mkdir(path.join(root,'code/native/code'),{recursive:true});const code='int entry(void) { return 7; }';await fs.writeFile(path.join(root,'code/native/code/entry.c'),code);
  await fs.writeFile(path.join(root,'code/native/ghidra-result.json'),JSON.stringify({Status:'Succeeded',Coverage:{DecompiledFunctions:1,Complete:true},Functions:[{Address:'00001000',Name:'ghidra_entry',Path:'code/entry.c',Bytes:Buffer.byteLength(code),SHA256:sha(code),Status:'Succeeded'}]}));
  const direct=await EvidenceStore.create(root);const body=await direct.call('read_function',{query:'0x1000'});assert.equal(body.text,code);assert.equal(body.path,'code/native/code/entry.c');assert.equal((await direct.call('audit_decompilation')).checked,3);
});
test('PDB-aware recovery deduplicates only the same input and retains hash-checked native instructions',async()=>{
  const identity=sha(await fs.readFile(path.join(root,'input/inert.exe')));
  const reaPath=path.join(root,'rea/rea-result.json'),rea=JSON.parse(await fs.readFile(reaPath,'utf8'));rea.InputSHA256Before=identity;await fs.writeFile(reaPath,JSON.stringify(rea));
  await fs.mkdir(path.join(root,'code/native/code'),{recursive:true});await fs.mkdir(path.join(root,'code/native/instructions'));
  const code='int wmain(void) { return target(); }',assembly='0x140001000: CALL 0x140001010\n0x140001005: RET\n';
  await fs.writeFile(path.join(root,'code/native/code/wmain.c'),code);await fs.writeFile(path.join(root,'code/native/instructions/wmain.asm'),assembly);
  const manifest={Status:'Succeeded',ExecutableSHA256:identity,Pdb:{Loaded:true},TerminalFlow:{Complete:true},Functions:[{Address:'140001000',Name:'wmain',Path:'code/wmain.c',Bytes:Buffer.byteLength(code),SHA256:sha(code),InstructionsPath:'instructions/wmain.asm',InstructionsBytes:Buffer.byteLength(assembly),InstructionsSHA256:sha(assembly),InstructionsComplete:true,Status:'Succeeded'}]};
  await fs.writeFile(path.join(root,'code/native/ghidra-result.json'),JSON.stringify(manifest));
  const merged=await EvidenceStore.create(root);assert.equal(merged.bodies.length,2);assert.equal(merged.providers.length,2);
  assert.equal((await merged.call('read_function',{query:'entry'})).function.name,'wmain');
  const instructions=await merged.call('read_function_instructions',{query:'wmain',limit:250000});assert.equal(instructions.text,assembly);assert.equal(instructions.limit_clamped,true);
  assert.equal((await merged.call('read_function_instructions',{procedure:'wmain'})).text,assembly);await assert.rejects(merged.call('read_function_instructions',{query:'wmain',procedure:'target'}),/one function selector/);
  assert.equal((await merged.call('audit_decompilation')).complete,true);
  manifest.ExecutableSHA256='f'.repeat(64);await fs.writeFile(path.join(root,'code/native/ghidra-result.json'),JSON.stringify(manifest));assert.equal((await EvidenceStore.create(root)).bodies.length,3);
  await fs.appendFile(path.join(root,'code/native/instructions/wmain.asm'),'modified');assert.equal((await merged.call('audit_decompilation')).failure_count,1);await assert.rejects(merged.call('read_function_instructions',{query:'wmain'}),/manifest hash/);
});
test('text probes find actual callers and clearly distinguish lexical evidence',async()=>{
  const result=await store.call('search_evidence',{query:'target()',prefix:'rea/rea-code/',limit:1});assert.equal(result.matches[0].line,1);assert.match(result.interpretation,/not verified native call/);assert.equal(result.search_complete,true);
  await assert.rejects(store.call('search_evidence',{query:''}),/literal query/);
});
test('static byte probes map a PE virtual address and reject invalid ranges',async()=>{
  const result=await store.call('read_input_bytes',{virtual_address:'0x140001010',length:1});assert.equal(result.file_offset,0x210);assert.equal(result.hex,'42');assert.equal(result.target_executed,false);
  await assert.rejects(store.call('read_input_bytes',{virtual_address:'0x140500000',length:1}),/mapping/);
  await assert.rejects(store.call('read_input_bytes',{offset:1024,length:1}),/exceeds/);
  await assert.rejects(store.call('read_input_bytes',{offset:0,virtual_address:'0x140001010'}),/either/);
});
test('containment rejects traversal, absolute paths, non-evidence files and changed links',async()=>{
  for(const relative of ['../outside.txt','C:/Windows/system.ini','/etc/passwd','rea/../basic/identity.json','input/inert.exe'])await assert.rejects(store.call('read_evidence',{path:relative}));
  const outside=await fs.mkdtemp(path.join(os.tmpdir(),'evidence-outside-'));try{
    await fs.writeFile(path.join(outside,'identity.json'),'PRIVATE');await fs.rename(path.join(root,'basic'),path.join(root,'basic-original'));await fs.symlink(outside,path.join(root,'basic'),process.platform==='win32'?'junction':'dir');
    await assert.rejects(store.call('read_evidence',{path:'basic/identity.json'}),/Symlink|resolves/);
    await fs.unlink(path.join(root,'basic'));
  }finally{await fs.rm(outside,{recursive:true,force:true});}
});
test('browser escapes target-derived labels and refuses overwrite',async()=>{
  store.bodies[0].name='<script>alert(1)</script>';store.bodies[1].path_admitted=false;store.bodies[1].path='../outside.txt';
  await store.exportIndex();const html=await fs.readFile(path.join(root,'functions.html'),'utf8');assert.ok(html.includes('&lt;script&gt;'));assert.ok(!html.includes('<script>alert'));assert.ok(!html.includes('href="../outside'));assert.equal(JSON.parse(await fs.readFile(path.join(root,'functions.json'),'utf8')).function_count,2);await assert.rejects(store.exportIndex(),/EEXIST/);
});
test('MCP transport advertises only read-only tools and returns real probe results',async()=>{
  assert.ok(toolCatalog.every(x=>x.annotations.readOnlyHint&&!x.annotations.destructiveHint));
  const identity=JSON.stringify({Format:'PE'})+' '.repeat(50000);await fs.writeFile(path.join(root,'basic/identity.json'),identity);
  const script=fileURLToPath(new URL('../scripts/ExecutableAnalysis/evidence-server.mjs',import.meta.url));
  const child=spawn(process.execPath,[script,root],{stdio:['pipe','pipe','pipe'],windowsHide:true});let stdout='',stderr='';child.stdout.on('data',x=>stdout+=x);child.stderr.on('data',x=>stderr+=x);
  const exit=new Promise(resolve=>child.on('close',resolve));
  for(const [id,method,params]of [[1,'initialize',{}],[2,'tools/list',{}],[3,'tools/call',{name:'read_function',arguments:{query:'entry'}}],[4,'tools/call',{name:'execute',arguments:{command:'never'}}],...[0,24000,48000].map((offset,i)=>[5+i,'tools/call',{name:'read_evidence',arguments:{path:'basic/identity.json',offset,limit:250000}}])])child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');child.stdin.end();
  assert.equal(await exit,0,stderr);const replies=stdout.trim().split('\n').map(x=>JSON.parse(x));assert.equal(replies[2].result.structuredContent.function.name,'entry');assert.equal(replies[3].result.isError,true);
  const pages=replies.slice(4).map(reply=>{assert.ok(!reply.result.isError);return reply.result.structuredContent;});
  assert.equal(pages.map(page=>page.text).join(''),identity);
  assert.deepEqual(pages.map(page=>page.next_offset),[24000,48000,null]);
  assert.ok(pages.every(page=>page.limit_clamped&&page.text.length<=24000));
});

test('native proxy filters tools, pins the input and rejects a changed hash',async()=>{
  const mock=path.join(root,'mock-native.mjs');
  await fs.writeFile(mock,`import readline from 'node:readline';for await(const line of readline.createInterface({input:process.stdin})){const r=JSON.parse(line);if(r.id===undefined)continue;const result=r.method==='tools/list'?{tools:[{name:'open_binary'},{name:'read_function_instructions'},{name:'set_address_name'}]}:{content:[{type:'text',text:JSON.stringify(r.params??{})}],structuredContent:r.params??{}};process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:r.id,result})+'\\n');}`);
  const proxy=fileURLToPath(new URL('../scripts/ExecutableAnalysis/native-review-server.mjs',import.meta.url));
  const input=path.join(root,'input/inert.exe'),hash=sha(await fs.readFile(input));
  async function run(expected,selected=input,evidence){
    const child=spawn(process.execPath,[proxy,mock,selected,expected,'',...(evidence?[evidence]:[])],{stdio:['pipe','pipe','pipe'],windowsHide:true});let stdout='',stderr='';child.stdout.on('data',x=>stdout+=x);child.stderr.on('data',x=>stderr+=x);const exit=new Promise(resolve=>child.on('close',resolve));
    for(const [id,method,params]of [[1,'tools/list',{}],[2,'tools/call',{name:'open_binary',arguments:{path:selected}}],[3,'tools/call',{name:'open_binary',arguments:{path:path.join(root,'outside.exe')}}],[4,'tools/call',{name:'set_address_name',arguments:{address:'0x1',name:'write'}}],[5,'tools/call',{name:'read_function_instructions',arguments:{procedure:'PublicEntry'}}],[6,'tools/call',{name:'read_function_instructions',arguments:{procedure:'OtherInput'}}]])child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');child.stdin.end();assert.equal(await exit,0,stderr);return new Map(stdout.trim().split('\n').map(x=>{const r=JSON.parse(x);return[r.id,r.result];}));
  }
  const results=await run(hash);assert.deepEqual(results.get(1).tools.map(x=>x.name),['open_binary','read_function_instructions']);assert.ok(results.get(2).structuredContent,JSON.stringify(results.get(2)));assert.equal(results.get(2).structuredContent.arguments.path,await fs.realpath(input));assert.equal(results.get(3).isError,true);assert.equal(results.get(4).isError,true);
  await fs.writeFile(path.join(root,'functions.json'),JSON.stringify({functions:[{name:'PublicEntry',aliases:[],address:'0x140001000',input_sha256:hash},{name:'OtherInput',address:'0x140001010',input_sha256:'f'.repeat(64)}]}));
  const named=await run(hash,input,root);assert.equal(named.get(5).structuredContent.arguments.procedure,'0x140001000');assert.equal(named.get(6).structuredContent.arguments.procedure,'OtherInput');
  const alias=path.join(root,'input-alias');await fs.symlink(path.join(root,'input'),alias,process.platform==='win32'?'junction':'dir');
  const aliased=await run(hash,path.join(alias,'inert.exe'));assert.ok(aliased.get(2).structuredContent,JSON.stringify(aliased.get(2)));assert.equal(aliased.get(2).structuredContent.arguments.path,await fs.realpath(input));
  // Retargeting the selected directory after startup must still fail, even if
  // the replacement file has identical bytes and therefore the same SHA256.
  const alternate=path.join(root,'alternate-input');await fs.mkdir(alternate);await fs.copyFile(input,path.join(alternate,'inert.exe'));
  const selected=path.join(alias,'inert.exe');
  const pinned=spawn(process.execPath,[proxy,mock,selected,hash,''],{stdio:['pipe','pipe','pipe'],windowsHide:true});
  let buffer='';const waiting=new Map();const finished=new Promise(resolve=>pinned.on('close',resolve));
  pinned.stdout.on('data',chunk=>{buffer+=chunk;let end;while((end=buffer.indexOf('\n'))>=0){const reply=JSON.parse(buffer.slice(0,end));buffer=buffer.slice(end+1);waiting.get(reply.id)?.(reply.result);waiting.delete(reply.id);}});
  const request=(id,method,params)=>new Promise(resolve=>{waiting.set(id,resolve);pinned.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');});
  try{
    await request(1,'tools/list',{});
    await fs.unlink(alias);await fs.symlink(alternate,alias,process.platform==='win32'?'junction':'dir');
    const refused=await request(2,'tools/call',{name:'open_binary',arguments:{path:selected}});
    assert.equal(refused.isError,true);assert.match(refused.content[0].text,/path changed/);
  }finally{pinned.stdin.end();assert.equal(await finished,0);}
  const changed=await run('0'.repeat(64));assert.equal(changed.get(2).isError,true);assert.match(changed.get(2).content[0].text,/hash changed/);
});
