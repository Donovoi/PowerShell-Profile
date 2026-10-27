import {test,beforeEach,afterEach} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {inspectPeDebug,inspectPdb,resolvePdb} from '../scripts/ExecutableAnalysis/pdb-context.mjs';
import {downloadSymbol,admitSymbolUrl,admitSymbolProxy,curlSymbolRequest} from '../scripts/ExecutableAnalysis/pdb-download.mjs';
const guid=Buffer.from('7aab86f93e543344cb7be6208e5488ec','hex');
function pe(name='demo.pdb'){
  const b=Buffer.alloc(1536);b.write('MZ');b.writeUInt32LE(0x80,60);b.writeUInt32LE(0x4550,0x80);b.writeUInt16LE(1,0x86);b.writeUInt16LE(0xf0,0x94);b.writeUInt16LE(0x20b,0x98);b.writeUInt32LE(0x200,0x98+60);b.writeUInt32LE(0x1000,0x98+112+48);b.writeUInt32LE(28,0x98+112+52);
  const section=0x98+0xf0;b.writeUInt32LE(0x1000,section+12);b.writeUInt32LE(0x400,section+16);b.writeUInt32LE(0x200,section+20);
  const cv=Buffer.concat([Buffer.from('RSDS'),guid,Buffer.from([1,0,0,0]),Buffer.from(name+'\0')]);b.writeUInt32LE(2,0x200+12);b.writeUInt32LE(cv.length,0x200+16);b.writeUInt32LE(0x240,0x200+24);cv.copy(b,0x240);return b;
}
function pdb(age=1){
  const b=Buffer.alloc(6*4096);b.write('Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0','ascii');b.writeUInt32LE(4096,32);b.writeUInt32LE(6,40);b.writeUInt32LE(32,44);b.writeUInt32LE(1,52);b.writeUInt32LE(2,4096);
  [4,0xffffffff,28,56,64,3,4,5].forEach((value,i)=>b.writeUInt32LE(value,8192+4*i));b.writeUInt32LE(age,12288+8);guid.copy(b,12288+12);b.writeUInt32LE(0x1000,16384+8);b.writeUInt32LE(0x1000,16384+12);b.writeUInt32LE(0xffffffff,20480);b.writeUInt32LE(19990903,20480+4);b.writeUInt32LE(age,20480+8);b.writeUInt16LE(2,20480+56);return b;
}
const inspect=bytes=>inspectPeDebug(async(offset,length)=>{if(offset+length>bytes.length)throw new Error('Fixture range');return bytes.subarray(offset,offset+length);},bytes.length);
let root,config;
beforeEach(async()=>{root=await fs.mkdtemp(path.join(os.tmpdir(),'analysis-pdb-'));for(const dir of ['source','cache','run/basic'])await fs.mkdir(path.join(root,dir),{recursive:true});await fs.writeFile(path.join(root,'source/demo.exe'),pe());config={inputPath:path.join(root,'source/demo.exe'),sourceDirectory:path.join(root,'source'),cacheDirectory:path.join(root,'cache'),outputDirectory:path.join(root,'run'),allowDownload:false};});
afterEach(async()=>{await fs.rm(root,{recursive:true,force:true});});
test('RSDS identity uses validated debug-directory mappings and strips build paths',async()=>{
  const result=await inspect(pe('C:\\private-build\\demo.pdb'));assert.equal(result.Name,'demo.pdb');assert.equal(result.Guid,'f986ab7a-543e-4433-cb7b-e6208e5488ec');assert.equal(result.SymbolKey,'F986AB7A543E4433CB7BE6208E5488EC1');
  await assert.rejects(inspect(pe('NUL.pdb')),/Unsafe/);await assert.rejects(inspect(pe('../secret.txt')),/Unsafe/);
  const malformed=pe();malformed.writeUInt32LE(0xfffffff0,0x200+24);await assert.rejects(inspect(malformed));
  const ambiguous=pe();ambiguous.writeUInt32LE(56,0x98+112+52);const length=ambiguous.readUInt32LE(0x200+16);ambiguous.copy(ambiguous,0x300,0x240,0x240+length);ambiguous[0x304]^=1;ambiguous.writeUInt32LE(2,0x21c+12);ambiguous.writeUInt32LE(length,0x21c+16);ambiguous.writeUInt32LE(0x300,0x21c+24);await assert.rejects(inspect(ambiguous),/ambiguous/);
});
test('MSF7 identity, empty TPI and stripped metadata are read independently',()=>{
  assert.deepEqual(inspectPdb(pdb()),{Guid:'f986ab7a-543e-4433-cb7b-e6208e5488ec',Age:1,InfoAge:1,AgeSource:'DBI',TpiTypeRecords:0,DbiStripped:true});
  const stripped=pdb();stripped.writeUInt32LE(3,12288+8);assert.equal(inspectPdb(stripped).Age,1);assert.equal(inspectPdb(stripped).InfoAge,3);
  const corrupt=pdb();corrupt.writeUInt32LE(0xffffffff,4096);assert.throws(()=>inspectPdb(corrupt),/directory page/);
  assert.throws(()=>inspectPdb(Buffer.from('not a PDB')),/signature/);
});
test('wrong adjacent identities are rejected and the matching symbol-store file is preserved',async()=>{
  await fs.writeFile(path.join(root,'source/demo.pdb'),pdb(2));const reference=await inspect(pe());
  const directory=path.join(root,'cache/demo.pdb',reference.SymbolKey);await fs.mkdir(directory,{recursive:true});await fs.writeFile(path.join(directory,'demo.pdb'),pdb());
  const result=await resolvePdb(config);assert.equal(result.Status,'Matched');assert.equal(result.RejectedCandidates.length,1);assert.match(result.RejectedCandidates[0].Reason,/mismatch/);assert.equal(result.Identity.TpiTypeRecords,0);assert.deepEqual(await fs.readFile(result.RetainedPath),pdb());
});
test('mismatches, oversized companions and reparse paths do not load',async()=>{
  await fs.writeFile(path.join(root,'source/demo.pdb'),pdb(2));assert.equal((await resolvePdb(config)).Status,'NotFound');
  const wrongGuid=pdb();wrongGuid[12288+12]^=1;await fs.writeFile(path.join(root,'source/demo.pdb'),wrongGuid);assert.equal((await resolvePdb(config)).Status,'NotFound');
  await fs.writeFile(path.join(root,'source/demo.pdb'),pdb());const bounded=await resolvePdb({...config,maxPdbBytes:1024});assert.equal(bounded.Status,'NotFound');assert.match(bounded.RejectedCandidates[0].Reason,/byte budget/);
  const alias=path.join(root,'linked');await fs.symlink(path.join(root,'source'),alias,process.platform==='win32'?'junction':'dir');
  const refused=await resolvePdb({...config,sourceDirectory:alias,cacheDirectory:path.join(root,'absent')});assert.equal(refused.Status,'NotFound');assert.match(refused.RejectedCandidates[0].Reason,/reparse/);
});
test('available local symbol-path caches are used without contacting remote entries',async()=>{
  const symbols=path.join(root,'symbols');await fs.mkdir(symbols);await fs.writeFile(path.join(symbols,'demo.pdb'),pdb());
  const result=await resolvePdb({...config,symbolPath:'srv*'+symbols+'*https://invalid.example/symbols;https://invalid.example/other'});assert.equal(result.Status,'Matched');assert.equal(result.SelectedPath,path.join(symbols,'demo.pdb'));
});
test('a cache miss downloads only the exact symbol identity, validates DBI age and populates a reusable cache',async()=>{
  const urls=[],bytes=pdb();bytes.writeUInt32LE(3,12288+8);
  const first=await resolvePdb({...config,allowDownload:true},{request:async url=>{urls.push(url);return {status:200,bytes};}});
  assert.deepEqual(urls,['https://msdl.microsoft.com/download/symbols/demo.pdb/F986AB7A543E4433CB7BE6208E5488EC1/demo.pdb']);
  assert.equal(first.Source,'Download');assert.equal(first.Status,'Matched');assert.equal(first.Identity.Age,1);assert.equal(first.Identity.InfoAge,3);assert.equal(first.Download.Status,'Validated');assert.equal(first.Download.CacheStatus,'Stored');
  assert.deepEqual(await fs.readFile(first.CachePath),bytes);assert.deepEqual(await fs.readFile(first.RetainedPath),bytes);assert.equal(first.Download.SHA256,first.SHA256);assert.equal(first.CandidatesInspected,0);
  const next=path.join(root,'run2');await fs.mkdir(next);
  const second=await resolvePdb({...config,allowDownload:true,outputDirectory:next},{request:()=>{throw new Error('Local hit must not request the network');}});
  assert.equal(second.Source,'Local');assert.equal(second.Download.Attempted,false);assert.equal(second.SHA256,first.SHA256);
});
test('absent RSDS and disabled downloads never invoke the transport',async()=>{
  const request=()=>{throw new Error('Unexpected transport invocation');};
  assert.equal((await resolvePdb(config,{request})).Download.Status,'Disabled');
  const noDebug=pe();noDebug.writeUInt32LE(0,0x98+112+48);await fs.writeFile(config.inputPath,noDebug);
  const none=await resolvePdb({...config,allowDownload:true},{request});assert.equal(none.Status,'NoRsdsReference');assert.equal(none.Download.Attempted,false);
});
test('mismatched or malformed downloads are never retained or cached',async()=>{
  const wrongGuid=pdb();wrongGuid[12288+12]^=1;
  for(const bytes of [pdb(2),wrongGuid,Buffer.from('HTTP error disguised as a PDB')]){
    const result=await resolvePdb({...config,allowDownload:true},{request:async()=>({status:200,bytes})});
    assert.equal(result.Status,'NotFound');assert.equal(result.Download.Status,'Rejected');assert.equal(result.RetainedPath,undefined);assert.deepEqual(await fs.readdir(config.cacheDirectory),[]);assert.equal((await fs.readdir(config.outputDirectory)).includes('symbols'),false);
  }
});
test('failed downloads retain a specific reason and preserve local mismatches',async()=>{
  await fs.writeFile(path.join(root,'source/demo.pdb'),pdb(2));
  for(const status of [404,503]){
    const result=await resolvePdb({...config,allowDownload:true},{request:async()=>({status,bytes:Buffer.from('error')})});
    assert.equal(result.Status,'NotFound');assert.equal(result.Download.Status,status===404?'NotFound':'HttpError');assert.match(result.Limitations.at(-1),/demo.pdb/);assert.equal(result.RejectedCandidates.length,1);
  }
  assert.deepEqual(await fs.readFile(path.join(root,'source/demo.pdb')),pdb(2));
  const failed=await resolvePdb({...config,allowDownload:true},{request:async()=>{throw new Error('certificate verification failed');}});assert.equal(failed.Download.Status,'Failed');assert.match(failed.Download.Error,/certificate/);
});
test('redirects are bounded, HTTPS-only and limited to Microsoft symbol storage',async()=>{
  for(const bad of ['http://msdl.microsoft.com/demo','https://user:secret@msdl.microsoft.com/demo','https://msdl.microsoft.com:444/demo','https://msdl.microsoft.com.attacker.test/demo','https://127.0.0.1/demo','https://unrelated.example/demo'])assert.throws(()=>admitSymbolUrl(bad));
  const reference=await inspect(pe());let calls=0;
  const rejected=await downloadSymbol(reference,{...config,allowDownload:true},async()=>{calls++;return {status:302,location:'https://127.0.0.1/private',bytes:Buffer.alloc(0)};});assert.equal(calls,1);assert.equal(rejected.receipt.Status,'Failed');
  calls=0;const loop=await downloadSymbol(reference,{...config,allowDownload:true},async()=>{calls++;return {status:302,location:'/loop',bytes:Buffer.alloc(0)};});assert.equal(calls,4);assert.equal(loop.receipt.Status,'Failed');
  calls=0;const valid=await downloadSymbol(reference,{...config,allowDownload:true},async()=>++calls===1?{status:302,location:'https://vsblobprodtest.blob.core.windows.net/public/file?sig=temporary',bytes:Buffer.from('redirect')}:{status:200,bytes:pdb()});
  assert.equal(valid.receipt.Status,'Received');assert.equal(valid.receipt.Redirects[0].To,'https://vsblobprodtest.blob.core.windows.net/public/file');assert.ok(!JSON.stringify(valid.receipt).includes('temporary'));assert.equal(valid.receipt.TransferredBytes,pdb().length+8);
});
test('redirect bodies share a byte budget and timeout exhaustion does not retry',async()=>{
  const reference=await inspect(pe());let calls=0;
  const bounded=await downloadSymbol(reference,{...config,allowDownload:true,maxPdbBytes:10},async()=>{calls++;return {status:302,location:'/next',bytes:Buffer.alloc(8)};});assert.equal(bounded.receipt.Status,'Failed');assert.equal(calls,2);assert.match(bounded.receipt.Error,/byte budget/);
  const failed=await downloadSymbol(reference,{...config,allowDownload:true},async()=>{throw new Error('Symbol download exceeded its total time budget.');});assert.equal(failed.receipt.Status,'Failed');assert.match(failed.receipt.Error,/time budget/);assert.deepEqual(await fs.readdir(config.outputDirectory),['basic']);
  const late=await downloadSymbol(reference,{...config,allowDownload:true,downloadTimeoutSeconds:1},async()=>{await new Promise(resolve=>setTimeout(resolve,1100));return {status:200,bytes:pdb()};});assert.equal(late.receipt.Status,'Failed');assert.equal(late.bytes,null);assert.match(late.receipt.Error,/time budget/);
});
test('unsafe proxy forms cannot change protocol, inject credentials or trigger a request',async()=>{
  assert.equal(admitSymbolProxy('socks5h://127.0.0.1:19050'),'socks5h://127.0.0.1:19050');
  for(const bad of ['socks5://127.0.0.1:1','file:///tmp/proxy','https://user:secret@proxy.example','http://proxy.example/path','http://proxy.example/?query'])assert.throws(()=>admitSymbolProxy(bad));
  const result=await downloadSymbol(await inspect(pe()),{...config,allowDownload:true,proxy:'file:///tmp/proxy'},()=>{throw new Error('Transport should not run');});assert.equal(result.receipt.Attempted,false);assert.equal(result.receipt.Status,'Failed');
});
test('cache writes refuse reparse paths and preserve conflicting cache bytes',async()=>{
  const reference=await inspect(pe()),directory=path.join(config.cacheDirectory,'demo.pdb',reference.SymbolKey);await fs.mkdir(directory,{recursive:true});const existing=path.join(directory,'demo.pdb');await fs.writeFile(existing,pdb(2));
  const result=await resolvePdb({...config,allowDownload:true},{request:async()=>({status:200,bytes:pdb()})});assert.equal(result.Status,'Matched');assert.equal(result.Download.CacheStatus,'NotWritten');assert.deepEqual(await fs.readFile(existing),pdb(2));assert.deepEqual((await fs.readdir(directory)).sort(),['demo.pdb']);
  const next=path.join(root,'run2');await fs.mkdir(next);const alias=path.join(root,'cache-link');await fs.symlink(config.cacheDirectory,alias,process.platform==='win32'?'junction':'dir');
  const refused=await resolvePdb({...config,allowDownload:true,cacheDirectory:alias,outputDirectory:next},{request:async()=>({status:200,bytes:pdb()})});assert.equal(refused.Download.CacheStatus,'NotWritten');assert.match(refused.Download.CacheError,/reparse/);
});
test('curl transport uses fixed secure arguments, bounds streamed bytes and requires successful TLS',async()=>{
  const url='https://msdl.microsoft.com/download/symbols/demo.pdb/key/demo.pdb',headerPath=path.join(root,'headers');
  await fs.writeFile(headerPath,'HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 200\r\nContent-Type: application/octet-stream\r\n\r\n');
  const options={headerPath,maxBytes:32,timeoutSeconds:2,proxy:'socks5h://127.0.0.1:19050'};
  const spawnFixture=(source,inspectArgs=()=>{})=>(file,args,launch)=>{inspectArgs(args,launch);return spawn(process.execPath,['-e',source],launch);};
  const response=await curlSymbolRequest(url,options,spawnFixture("process.stdout.write('fixture')",(args,launch)=>{assert.equal(args[0],'--disable');assert.equal(launch.shell,false);assert.ok(args.includes('=https'));assert.ok(args.includes('--proxy'));assert.ok(!args.includes('--insecure'));assert.ok(!args.includes('--location'));}));assert.equal(response.status,200);assert.equal(response.bytes.toString(),'fixture');
  await assert.rejects(curlSymbolRequest(url,options,spawnFixture('process.stdout.write(Buffer.alloc(100000))')),/byte budget/);
  await assert.rejects(curlSymbolRequest(url,options,spawnFixture("process.stderr.write('certificate error');process.exit(60)")),/curl 60/);
  await assert.rejects(curlSymbolRequest(url,{...options,timeoutSeconds:0.01},spawnFixture('setInterval(()=>{},1000)')),/time budget/);
  await fs.writeFile(headerPath,'HTTP/2 302\r\nLocation: /a\r\nLocation: /b\r\n\r\n');await assert.rejects(curlSymbolRequest(url,options,spawnFixture('')),/ambiguous/);
});
