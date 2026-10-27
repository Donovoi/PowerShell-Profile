import {test,beforeEach,afterEach} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {inspectPeDebug,inspectPdb,resolvePdb} from '../scripts/ExecutableAnalysis/pdb-context.mjs';
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
beforeEach(async()=>{root=await fs.mkdtemp(path.join(os.tmpdir(),'analysis-pdb-'));for(const dir of ['source','cache','run/basic'])await fs.mkdir(path.join(root,dir),{recursive:true});await fs.writeFile(path.join(root,'source/demo.exe'),pe());config={inputPath:path.join(root,'source/demo.exe'),sourceDirectory:path.join(root,'source'),cacheDirectory:path.join(root,'cache'),outputDirectory:path.join(root,'run')};});
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
