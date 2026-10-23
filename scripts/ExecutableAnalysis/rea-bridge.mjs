// A single owned REA session. Target-derived strings and code are data only.
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import { TextDecoder } from 'node:util';

const decodeUtf8 = bytes => new TextDecoder('utf-8', { fatal: true }).decode(bytes);

const configPath = process.argv[2];
if (!configPath || !path.isAbsolute(configPath)) throw new Error('An absolute configuration JSON path is required.');
const config = JSON.parse(decodeUtf8(await fs.readFile(configPath)));
for (const key of ['reaScript', 'inputPath', 'outputDirectory']) {
  if (typeof config[key] !== 'string' || !path.isAbsolute(config[key])) throw new Error(`${key} must be an absolute path.`);
}
const integer = (key, fallback, minimum, maximum) => {
  const value = config[key] ?? fallback;
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new Error(`Invalid ${key}.`);
  return value;
};
const timeoutMs = integer('timeoutSeconds', 300, 1, 86400) * 1000;
const maxFunctions = integer('maxFunctions', 0, 0, 1000000);
const maxJavaScriptFiles = integer('maxJavaScriptFiles', 40, 1, 10000);
const maxJavaScriptBytes = integer('maxJavaScriptBytes', 33554432, 1024, 268435456);
const maxJavaScriptHeapMB = integer('maxJavaScriptHeapMB', 1024, 128, 8192);
const maxExtractionEntries = integer('maxExtractionEntries', 50000, 1, 100000);
const archiveIntegrityPolicy = config.archiveIntegrityPolicy ?? 'fail';
if (!['fail', 'record-and-continue'].includes(archiveIntegrityPolicy)) throw new Error('Invalid archiveIntegrityPolicy.');
const maxEvidenceBytes = integer('maxEvidenceBytes', 67108864, 4096, 1073741824);
const maxTotalBytes = integer('maxTotalEvidenceBytes', 1073741824, 4096, 17179869184);
const deadline = Date.now() + integer('totalTimeoutSeconds', 3600, 1, 86400) * 1000;
const root = await fs.realpath(config.outputDirectory);
if (!(await fs.stat(root)).isDirectory()) throw new Error('outputDirectory must be an existing directory.');
await fs.mkdir(path.join(root, 'rea-raw'));
await fs.mkdir(path.join(root, 'rea-code'));
const manifest = {
  SchemaVersion: 1, InputPath: config.inputPath, StartedUtc: new Date().toISOString(),
  Status: 'Running', Stages: [], Artifacts: [], Limitations: [],
  Coverage: { DiscoveredFunctions: null, AttemptedFunctions: 0, DecompiledFunctions: 0, ExternalFunctions: 0, FailedFunctions: 0, FunctionLimit: maxFunctions || null, Complete: false },
  TargetExecuted: false, Cleanup: 'Pending',
};
let bytesWritten = 0;
let stageNumber = 0;
let child;
let opened = false;
let closed = false;
let abortSession = false;
let tools = new Map();
const pending = new Map();
let requestId = 0;
let stdoutBuffer = Buffer.alloc(0);
let stderrParts = [];
let stderrBytes = 0;
const limitation = value => { if (!manifest.Limitations.includes(value)) manifest.Limitations.push(value); };
const hashFile = async file => {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
};
const inside = relative => {
  const destination = path.resolve(root, relative);
  if (!destination.startsWith(root + path.sep)) throw new Error('Output path escapes the run directory.');
  return destination;
};
async function retain(relative, content, kind = 'evidence') {
  const buffer = Buffer.isBuffer(content) ? content : Buffer.from(content, 'utf8');
  if (buffer.length > maxEvidenceBytes || bytesWritten + buffer.length > maxTotalBytes) {
    limitation(`Retention limit reached for ${relative}; no truncated file was presented as complete.`);
    throw new Error('Evidence retention limit exceeded.');
  }
  const destination = inside(relative);
  await fs.writeFile(destination, buffer, { flag: 'wx' });
  bytesWritten += buffer.length;
  manifest.Artifacts.push({ Path: relative, Kind: kind, Bytes: buffer.length, SHA256: createHash('sha256').update(buffer).digest('hex') });
  return relative;
}
const json = value => JSON.stringify(value, null, 2) + '\n';
const send = message => { if (!child || child.killed || !child.stdin.writable) throw new Error('REA transport is closed.'); child.stdin.write(JSON.stringify(message) + '\n'); };
function rejectPending(error) {
  for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(error); }
  pending.clear();
}
function request(method, params, milliseconds = timeoutMs) {
  return new Promise((resolve, reject) => {
    const id = ++requestId;
    const timer = setTimeout(() => {
      pending.delete(id);
      try { send({ jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: id, reason: 'Caller time budget exceeded' } }); } catch { /* A stopped producer is already cancelled. */ }
      abortSession = true;
      reject(new Error(`REA ${method} exceeded ${milliseconds} ms; result coverage is incomplete.`));
    }, milliseconds);
    pending.set(id, { resolve, reject, timer });
    try { send({ jsonrpc: '2.0', id, method, params }); } catch (error) { clearTimeout(timer); pending.delete(id); reject(error); }
  });
}
function receive(chunk) {
  stdoutBuffer = Buffer.concat([stdoutBuffer, chunk]);
  if (stdoutBuffer.length > maxEvidenceBytes * 2 + 1048576) {
    abortSession = true;
    rejectPending(new Error('REA transport frame exceeded the configured evidence bound.'));
    child.stdout.pause();
    return;
  }
  let newline;
  while ((newline = stdoutBuffer.indexOf(10)) >= 0) {
    let line;
    try { line = decodeUtf8(stdoutBuffer.subarray(0, newline)); } catch {
      abortSession = true;
      rejectPending(new Error('REA emitted invalid UTF-8; no replacement-decoded evidence was accepted.'));
      stdoutBuffer = Buffer.alloc(0);
      return;
    }
    stdoutBuffer = stdoutBuffer.subarray(newline + 1);
    if (!line.trim()) continue;
    let message;
    try { message = JSON.parse(line); } catch {
      abortSession = true;
      rejectPending(new Error('REA emitted invalid JSON-RPC; no partial frame was accepted.'));
      return;
    }
    if (message.id === undefined) continue;
    const entry = pending.get(message.id);
    if (!entry) {
      // Client capabilities contain no sampling, elicitation or filesystem roots.
      if (message.method) send({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Unsupported server request' } });
      continue;
    }
    clearTimeout(entry.timer); pending.delete(message.id);
    if (message.error) entry.reject(new Error(JSON.stringify(message.error)));
    else entry.resolve(message.result);
  }
}
function unpack(result) {
  if (result?.structuredContent !== undefined) return result.structuredContent;
  for (const content of result?.content ?? []) {
    if (content.type !== 'text') continue;
    try { return JSON.parse(content.text); } catch { /* Text diagnostics are preserved in the raw result. */ }
  }
  return result;
}
async function invoke(name, args = {}, label = name, cleanup = false) {
  const stage = { Name: label, Tool: name, StartedUtc: new Date().toISOString(), Status: 'Pending' };
  manifest.Stages.push(stage);
  if (!tools.has(name)) { stage.Status = 'Unavailable'; stage.Error = 'Tool is not advertised by this REA server.'; return null; }
  if (!cleanup && (abortSession || Date.now() >= deadline)) { stage.Status = 'Skipped'; stage.Error = 'The analysis time or transport budget was exhausted.'; limitation(stage.Error); return null; }
  const schema = tools.get(name).inputSchema;
  for (const required of schema?.required ?? []) {
    if (!(required in args)) { stage.Status = 'Failed'; stage.Error = `Required argument missing: ${required}`; return null; }
  }
  try {
    const result = await request('tools/call', { name, arguments: args }, cleanup ? Math.min(timeoutMs, 30000) : Math.min(timeoutMs, Math.max(1, deadline - Date.now())));
    const filename = `rea-raw/${String(++stageNumber).padStart(5, '0')}-${name}.json`;
    stage.EvidencePath = await retain(filename, json(result));
    let payload = unpack(result);
    if (result?.isError) {
      const constraint = payload?.error;
      const reference = constraint?.details?.reported_limits;
      if (constraint?.code === 'resource_constraint' && constraint?.details?.resource === 'transport' && reference?.boundary === 'mcp-response' && /^ev_[a-f0-9]{64}$/.test(reference?.evidence_id ?? '') && name !== 'export_evidence_bundle') {
        payload = await recoverRetainedRecord(name, reference.evidence_id, stage);
      } else { stage.Status = 'Failed'; stage.Error = JSON.stringify(payload).slice(0, 4096); return null; }
    }
    for (const item of payload?.limitations ?? []) if (typeof item === 'string') limitation(item);
    stage.Status = 'Succeeded';
    const contradictions = payload?.normalized_result?.integrity_contradictions;
    if (Array.isArray(contradictions) && contradictions.length) {
      stage.Status = 'Partial';
      manifest.ArchiveIntegrityContradictions ??= [];
      manifest.ArchiveIntegrityContradictions.push({ Tool: name, EvidencePath: stage.EvidencePath, Contradictions: contradictions });
      limitation(`${name} retained ${contradictions.length} archive integrity contradiction(s); observed bytes remain untrusted.`);
    }
    if (name === 'analyze_javascript_application') {
      const normalized = payload?.normalized_result;
      const coverage = normalized?.graph?.coverage ? { application: normalized.graph.coverage, semantic: normalized.semantic_graph?.coverage ?? null } : normalized?.summary?.coverage;
      manifest.JavaScriptProviderCoverage = coverage ?? null;
      manifest.JavaScriptSummary = normalized?.summary ?? { statistics: normalized?.statistics ?? null };
      if (!coverage || coverage.application?.status !== 'complete' || coverage.semantic?.status !== 'complete') {
        stage.Status = 'Partial';
        limitation('JavaScript semantic coverage is partial or unverified; successful transport does not establish complete application analysis.');
      }
      if (normalized?.parent_evidence_id) stage.ParentEvidenceId = normalized.parent_evidence_id;
    }
    stage.EvidenceId = payload?.evidence_id ?? null;
    return payload;
  } catch (error) { stage.Status = 'Failed'; stage.Error = String(error.message); limitation(`${label}: ${error.message}`); return null; }
  finally { stage.FinishedUtc = new Date().toISOString(); }
}
async function recoverRetainedRecord(operation, evidenceId, originalStage) {
  const relative = `rea-raw/${String(++stageNumber).padStart(5, '0')}-retained-${operation}.json`;
  const file = inside(relative);
  const exported = await invoke('export_evidence_bundle', { path: file }, `recover_${operation}`);
  if (!exported) throw new Error('The provider retained an oversized response but its evidence export failed.');
  const stat = await fs.lstat(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0) throw new Error('Retained-response export is not a nonempty regular file.');
  if (stat.size > 268435456 || bytesWritten + stat.size > maxTotalBytes) throw new Error('Retained-response export exceeds its 256 MiB parsing or total evidence budget.');
  manifest.Artifacts.push({ Path: relative, Kind: 'retained-evidence-recovery', Bytes: stat.size, SHA256: await hashFile(file) });
  bytesWritten += stat.size;
  const bundle = JSON.parse(decodeUtf8(await fs.readFile(file)));
  if (!Array.isArray(bundle.records)) throw new Error('Retained-response export lacks an evidence record inventory.');
  const matches = bundle.records.filter(record => record.evidence_id === evidenceId && record.operation === operation);
  if (matches.length !== 1 || !Object.hasOwn(matches[0], 'normalized_result')) throw new Error('Retained-response export does not contain exactly the requested operation and evidence ID.');
  originalStage.RecoveredFromRetainedEvidence = true;
  originalStage.RetainedEvidencePath = relative;
  originalStage.RetainedEvidenceId = evidenceId;
  limitation(`${operation} exceeded the MCP response budget; its exact retained evidence record was recovered from ${relative}.`);
  return matches[0];
}
async function detectFormat() {
  if (config.format && config.format !== 'auto') return config.format.toLowerCase();
  const stat = await fs.stat(config.inputPath);
  if (stat.isDirectory()) return 'javascript';
  const file = await fs.open(config.inputPath, 'r');
  try {
    const bytes = Buffer.alloc(4096); const { bytesRead } = await file.read(bytes, 0, bytes.length, 0); const b = bytes.subarray(0, bytesRead);
    if (b.length >= 4 && b.subarray(0, 4).equals(Buffer.from([0, 97, 115, 109]))) return 'wasm';
    if (b.length >= 4 && b.subarray(0, 4).equals(Buffer.from([127, 69, 76, 70]))) return 'native';
    if (b.length >= 64 && b.toString('ascii', 0, 2) === 'MZ') {
      const pe = b.readUInt32LE(60); const header = Buffer.alloc(264);
      if (pe > stat.size - 24) return 'native';
      const result = await file.read(header, 0, header.length, pe);
      if (result.bytesRead >= 248 && header.readUInt32LE(0) === 0x4550) {
        const magic = header.readUInt16LE(24); const offset = 24 + (magic === 0x20b ? 112 : 96) + 14 * 8;
        if ([0x10b, 0x20b].includes(magic) && result.bytesRead >= offset + 8 && header.readUInt32LE(offset) !== 0 && header.readUInt32LE(offset + 4) !== 0) return 'managed';
      }
      return 'native';
    }
    const extension = path.extname(config.inputPath).toLowerCase();
    if (extension === '.apk') return 'android';
    if (['.js', '.mjs', '.cjs', '.asar'].includes(extension)) return 'javascript';
    if (['.zip', '.ipa', '.msix', '.appx', '.aab', '.jar', '.aar', '.dmg', '.pkg'].includes(extension) || (b.length >= 4 && b.readUInt32LE(0) === 0x04034b50)) return 'archive';
    if (b.length >= 8 && b.readUInt32BE(0) === 0xcafebabe && b.readUInt16BE(6) >= 45 && b.readUInt16BE(6) <= 100) return 'java';
    if (b.length >= 4 && [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca].includes(b.readUInt32BE(0))) return 'native';
    return 'unknown';
  } finally { await file.close(); }
}
async function copyExtraction(payload) {
  manifest.ExtractionBudget = { EntryLimit: maxExtractionEntries, FileByteLimit: maxEvidenceBytes, TotalEvidenceByteLimit: maxTotalBytes };
  const result = payload?.normalized_result;
  if (!result?.output_root || !path.isAbsolute(result.output_root)) throw new Error('REA extraction did not return an absolute output_root.');
  if (result.containment_verified !== true || !Array.isArray(result.artifacts)) throw new Error('REA extraction did not verify containment and its artifact inventory.');
  const expected = new Map();
  for (const artifact of result.artifacts) {
    if (typeof artifact.relative_path !== 'string' || !/^[a-f0-9]{64}$/i.test(artifact.sha256 ?? '')) throw new Error('Extraction inventory contains an invalid path or SHA-256.');
    const key = artifact.relative_path.replaceAll('\\', '/');
    if (expected.has(key)) throw new Error('Extraction inventory contains duplicate paths.');
    expected.set(key, artifact);
  }
  const copiedFiles = new Set();
  const sourceRoot = await fs.realpath(result.output_root);
  const destinationRoot = inside('rea-extracted');
  await fs.mkdir(destinationRoot);
  let count = 0;
  async function walk(directory, relative = '') {
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      if (++count > maxExtractionEntries) throw new Error(`Extraction copy exceeds the ${maxExtractionEntries}-entry bound.`);
      const source = path.join(directory, entry.name);
      const subpath = path.join(relative, entry.name);
      const actual = await fs.lstat(source);
      if (actual.isSymbolicLink()) throw new Error('Extraction copy refuses symbolic links.');
      if (actual.isDirectory()) { await fs.mkdir(inside(path.join('rea-extracted', subpath))); await walk(source, subpath); }
      else if (actual.isFile()) {
        if (actual.size > maxEvidenceBytes || bytesWritten + actual.size > maxTotalBytes) throw new Error('Extraction copy exceeds retained artifact bounds.');
        const destination = inside(path.join('rea-extracted', subpath));
        const key = subpath.replaceAll('\\', '/');
        const declared = expected.get(key);
        if (!declared || declared.bytes_written !== actual.size) throw new Error('Extraction file is absent from its inventory or its size changed.');
        await fs.copyFile(source, destination, 1); bytesWritten += actual.size;
        const digest = await hashFile(destination);
        if (digest.toLowerCase() !== declared.sha256.toLowerCase()) throw new Error('Extraction copy SHA-256 does not match the provider inventory.');
        copiedFiles.add(key);
        manifest.Artifacts.push({ Path: path.relative(root, destination), Kind: 'extracted', Bytes: actual.size, SHA256: digest });
      } else throw new Error('Extraction copy refuses special files.');
    }
  }
  await walk(sourceRoot);
  if (copiedFiles.size !== expected.size) throw new Error('Not every inventoried extraction file was retained.');
  limitation(`REA's original temporary extraction is retained at ${sourceRoot}; verified regular files were also copied into rea-extracted.`);
}
async function retainArchive() {
  const target = await invoke('open_binary', { path: config.inputPath });
  if (!target) return false;
  opened = true;
  manifest.ArchiveIntegrityPolicy = archiveIntegrityPolicy;
  const arguments_ = {};
  if (archiveIntegrityPolicy !== 'fail') {
    for (const tool of ['inspect_artifact', 'extract_artifact']) {
      if (!tools.get(tool)?.inputSchema?.properties?.integrity_policy) { limitation('REA does not advertise the requested archive integrity policy.'); manifest.Stages.push({ Name: 'archive_integrity_policy', Status: 'Unavailable' }); return false; }
    }
    arguments_.integrity_policy = archiveIntegrityPolicy;
  }
  await invoke('inspect_artifact', arguments_);
  const extraction = await invoke('extract_artifact', arguments_);
  if (!extraction) return false;
  const stage = { Name: 'retain_extracted_files', StartedUtc: new Date().toISOString(), Status: 'Pending' };
  manifest.Stages.push(stage);
  try { await copyExtraction(extraction); stage.Status = 'Succeeded'; return true; }
  catch (error) { stage.Status = 'Failed'; stage.Error = error.message; limitation(`Extraction copy incomplete: ${error.message}`); return false; }
  finally { stage.FinishedUtc = new Date().toISOString(); }
}
async function selectJavaScriptSources() {
  const prefix = 'rea-extracted/';
  const sources = manifest.Artifacts.filter(item => item.Kind === 'extracted').map(item => ({
    path: item.Path.replaceAll('\\', '/').slice(prefix.length), bytes: item.Bytes,
  })).filter(item => /\.(?:[cm]?js|jsx|tsx?|json|map)$/i.test(item.path));
  let main = null;
  const packageFile = sources.find(item => item.path === 'package.json' && item.bytes <= 1048576);
  if (packageFile) {
    try { const metadata = JSON.parse(decodeUtf8(await fs.readFile(inside('rea-extracted/package.json')))); if (typeof metadata.main === 'string') main = metadata.main.replace(/^\.\//, ''); }
    catch { limitation('The root package.json was not valid bounded JSON; no entry-point declaration was trusted.'); }
  }
  const rank = item => item.path === 'package.json' ? 0 : item.path === main ? 1 : /(?:^|\/)[^/]*(?:main|preload)[^/]*\.[cm]?js$/i.test(item.path) ? 2 : item.path.includes('node_modules/') ? 5 : /\.map$/i.test(item.path) ? 4 : 3;
  sources.sort((a, b) => rank(a) - rank(b) || a.path.localeCompare(b.path, 'en'));
  const selected = []; let bytes = 0;
  for (const item of sources) {
    if (selected.length >= maxJavaScriptFiles || bytes + item.bytes > maxJavaScriptBytes) continue;
    selected.push(item.path); bytes += item.bytes;
  }
  manifest.JavaScriptSelection = { DiscoveredSourceFiles: sources.length, SelectedSourceFiles: selected, SelectedSourceBytes: bytes, FileLimit: maxJavaScriptFiles, ByteLimit: maxJavaScriptBytes, Complete: selected.length === sources.length };
  if (!manifest.JavaScriptSelection.Complete) limitation('JavaScript semantic analysis uses a bounded selection of retained source files; unselected sources and dependencies remain unknown. Extracted bytes have separate retention coverage.');
  return selected;
}
async function nativeAnalysis() {
  const target = await invoke('open_binary', { path: config.inputPath, provider_id: config.provider ?? 'ghidra' });
  if (!target) return;
  opened = true;
  await invoke('binary_overview');
  const procedures = await invoke('list_procedures');
  await invoke('list_strings');
  const list = procedures?.normalized_result;
  if (!Array.isArray(list)) { limitation('Procedure inventory was unavailable; function coverage is unknown.'); return; }
  manifest.Coverage.DiscoveredFunctions = list.length;
  for (const procedure of list) {
    if (procedure.procedure?.external) { manifest.Coverage.ExternalFunctions++; continue; }
    if ((maxFunctions && manifest.Coverage.AttemptedFunctions >= maxFunctions) || abortSession || Date.now() >= deadline) {
      limitation('Not all discovered functions were attempted because a caller budget was reached.'); break;
    }
    if (typeof procedure.address !== 'string' || procedure.address.length > 200) { limitation('Procedure inventory contained an invalid address; that row was not used.'); continue; }
    manifest.Coverage.AttemptedFunctions++;
    const evidence = await invoke('procedure_pseudo_code', { procedure: procedure.address }, `decompile:${procedure.address}`);
    if (typeof evidence?.normalized_result === 'string' && evidence.normalized_result.trim()) {
      const relative = `rea-code/${String(manifest.Coverage.AttemptedFunctions).padStart(6, '0')}-${procedure.address.replace(/[^a-zA-Z0-9_-]/g, '_')}.c`;
      try { await retain(relative, evidence.normalized_result, 'decompiled-pseudocode'); manifest.Coverage.DecompiledFunctions++; }
      catch (error) { manifest.Coverage.FailedFunctions++; limitation(error.message); }
    } else manifest.Coverage.FailedFunctions++;
  }
  manifest.Coverage.Complete = manifest.Coverage.AttemptedFunctions + manifest.Coverage.ExternalFunctions === list.length && manifest.Coverage.FailedFunctions === 0;
  limitation('Native pseudocode is a decompiler reconstruction, not original source. Coverage refers only to functions discovered by the provider.');
}
async function run() {
  const reaInfo = await fs.stat(config.reaScript);
  if (!reaInfo.isFile()) throw new Error('reaScript must be a file.');
  if ((await fs.stat(config.inputPath)).isFile()) manifest.InputSHA256Before = await hashFile(config.inputPath);
  manifest.Format = await detectFormat();
  child = spawn(process.execPath, [config.reaScript, '--mcp'], { cwd: root, windowsHide: true, shell: false, stdio: ['pipe', 'pipe', 'pipe'] });
  child.stdout.on('data', receive);
  child.stderr.on('data', chunk => { if (stderrBytes < 1048576) { const part = chunk.subarray(0, 1048576 - stderrBytes); stderrParts.push(part); stderrBytes += part.length; } else limitation('REA stderr exceeded the 1 MiB diagnostic bound.'); });
  child.on('error', error => rejectPending(error));
  child.on('exit', (code, signal) => { closed = true; rejectPending(new Error(`REA exited: ${code ?? signal}.`)); });
  manifest.Server = await request('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'PowerShell-ExecutableAnalysis', version: '1.0.0' } });
  if (manifest.Server?.serverInfo?.version !== '6.7.0') throw new Error('This bridge is validated for REA 6.7.0; the connected server reported another version.');
  send({ jsonrpc: '2.0', method: 'notifications/initialized' });
  let cursor;
  do {
    const catalog = await request('tools/list', cursor ? { cursor } : {});
    for (const tool of catalog.tools ?? []) tools.set(tool.name, tool);
    cursor = catalog.nextCursor;
  } while (cursor);
  await retain('rea-raw/tool-catalog.json', json([...tools.values()]), 'tool-schema');
  await invoke('binary_session', { expected_package_version: '6.7.0' });
  const selectedPath = { path: config.inputPath };
  switch (manifest.Format) {
    case 'managed':
      await invoke('inspect_managed_artifact', selectedPath);
      await invoke('inspect_managed_members', selectedPath);
      await invoke('inspect_managed_native_boundaries', selectedPath);
      await invoke('inspect_pe_resources', selectedPath);
      limitation('REA managed metadata and CIL do not constitute C# decompilation; use the separately recorded ILSpy stage.');
      break;
    case 'native':
      await invoke('inspect_go_binary', selectedPath);
      await invoke('inspect_rust_binary', selectedPath);
      if (['.exe', '.dll', '.sys'].includes(path.extname(config.inputPath).toLowerCase())) await invoke('inspect_pe_resources', selectedPath);
      await nativeAnalysis();
      break;
    case 'wasm': {
      const wasm = await invoke('inspect_wasm_artifact', selectedPath);
      const wat = wasm?.normalized_result?.wat;
      const text = typeof wat === 'string' ? wat : wat?.text;
      if (typeof text === 'string') await retain('rea-code/module.wat', text, 'decoded-wat');
      break;
    }
    case 'javascript': {
      const standalone = ['.js', '.cjs', '.mjs'].includes(path.extname(config.inputPath).toLowerCase());
      let selected = config.inputPath;
      let sourcePaths;
      if (standalone) {
        // Analyze only the caller-selected file; never silently inspect its sibling tree.
        selected = inside('rea-javascript-input');
        await fs.mkdir(selected);
        const copied = path.join(selected, 'input' + path.extname(config.inputPath).toLowerCase());
        const size = (await fs.stat(config.inputPath)).size;
        if (size > maxEvidenceBytes) throw new Error('Selected JavaScript file exceeds the input-copy bound.');
        await fs.copyFile(config.inputPath, copied, 1);
        if (await hashFile(copied) !== manifest.InputSHA256Before) throw new Error('JavaScript input changed while creating its analysis copy.');
        limitation('Standalone JavaScript was analyzed in an isolated directory containing only its selected file; dependencies were not implicitly read.');
      }
      if (!standalone && path.extname(config.inputPath).toLowerCase() === '.asar') {
        // Retain source bytes even if subsequent semantic analysis exhausts its budget.
        if (await retainArchive()) { sourcePaths = await selectJavaScriptSources(); selected = inside('rea-extracted'); }
        else {
          limitation('ASAR source retention failed; semantic analysis was not broadened to an unbounded application scan.');
          break;
        }
        if (!sourcePaths.length) { limitation('No source file fits the configured JavaScript analysis limits.'); break; }
      }
      const arguments_ = { input_path: selected, analysis_timeout_ms: timeoutMs };
      const properties = tools.get('analyze_javascript_application')?.inputSchema?.properties ?? {};
      if (!properties.max_heap_mb) { limitation('REA does not advertise a JavaScript worker heap limit; semantic analysis is unavailable.'); manifest.Stages.push({ Name: 'javascript_heap_budget', Status: 'Unavailable' }); break; }
      arguments_.max_heap_mb = maxJavaScriptHeapMB;
      manifest.JavaScriptWorkerHeapMB = maxJavaScriptHeapMB;
      if (sourcePaths) {
        if (!properties.source_paths) { limitation('REA does not advertise bounded JavaScript source selection; semantic analysis is unavailable.'); manifest.Stages.push({ Name: 'javascript_source_selection', Status: 'Unavailable' }); break; }
        arguments_.source_paths = sourcePaths;
      }
      if (properties.detail) arguments_.detail = 'summary';
      await invoke('analyze_javascript_application', arguments_);
      if (standalone) {
        await invoke('recover_javascript_sources', { path: config.inputPath, output_directory: inside('rea-javascript'), extraction_mode: 'structural', rewrite_level: 'minimal' });
      }
      break;
    }
    case 'android':
      await invoke('inspect_android_package', selectedPath);
      // Package inventory/extraction is useful even without JADX.
    case 'archive': {
      await retainArchive();
      break;
    }
    case 'java':
      limitation('Java class-file candidate requires a Java decompiler such as JADX; it is not treated as a Mach-O executable despite the shared CAFEBABE magic.');
      break;
    default:
      limitation('The bridge did not identify a supported format. Baseline file evidence remains useful; a format-specific provider may still be needed.');
  }
}
try { await run(); }
catch (error) { limitation(`Bridge failure: ${error.message}`); manifest.Error = error.message; }
finally {
  if (child && !closed && tools.has('export_evidence_bundle')) {
    const exported = await invoke('export_evidence_bundle', { path: inside('rea-evidence-bundle.json') }, 'export_evidence_bundle', true);
    if (exported) {
      const stage = { Name: 'verify_evidence_export', StartedUtc: new Date().toISOString(), Status: 'Pending' };
      manifest.Stages.push(stage);
      try {
        const file = inside('rea-evidence-bundle.json'); const stat = await fs.lstat(file);
        if (!stat.isFile() || stat.isSymbolicLink() || stat.size === 0) throw new Error('Evidence export must be a nonempty regular file.');
        manifest.Artifacts.push({ Path: 'rea-evidence-bundle.json', Kind: 'retained-evidence-export', Bytes: stat.size, SHA256: await hashFile(file) });
        if (bytesWritten + stat.size > maxTotalBytes) throw new Error('Evidence export exceeds the configured retained-byte budget; the provider-created file was preserved and is explicitly oversized.');
        bytesWritten += stat.size;
        stage.Status = 'Succeeded';
      } catch (error) { stage.Status = 'Failed'; stage.Error = error.message; limitation(`Export verification failed: ${error.message}`); }
      finally { stage.FinishedUtc = new Date().toISOString(); }
    }
  }
  if (child && !closed && tools.has('close_binary')) {
    const result = await invoke('close_binary', {}, 'close_binary', true);
    manifest.Cleanup = result ? 'ProviderClosed' : 'ProviderCloseUnverified';
    opened = false;
  }
  if (child && !closed) {
    child.stdin.end();
    await new Promise(resolve => {
      const timer = setTimeout(resolve, 5000);
      child.once('exit', () => { clearTimeout(timer); resolve(); });
      if (closed) { clearTimeout(timer); resolve(); }
    });
    if (!closed) { child.kill(); limitation('REA did not exit after provider close; its owned process was terminated. Descendant cleanup is not independently established.'); }
  }
  if (stderrParts.length) { try { await retain('rea-raw/server-stderr.txt', Buffer.concat(stderrParts), 'diagnostic'); } catch (error) { limitation(error.message); } }
  if (manifest.Cleanup === 'Pending') manifest.Cleanup = opened ? 'Unverified' : 'NoProviderOpened';
  if (manifest.InputSHA256Before) try {
    manifest.InputSHA256After = await hashFile(config.inputPath);
    manifest.InputUnchanged = manifest.InputSHA256Before === manifest.InputSHA256After;
    if (!manifest.InputUnchanged) { manifest.Error = 'Input SHA-256 changed during analysis.'; limitation(manifest.Error); }
  } catch (error) { manifest.Error = `Input identity could not be reverified: ${error.message}`; }
  const extracted = manifest.Artifacts.filter(artifact => artifact.Kind === 'extracted');
  if (extracted.length) {
    const stage = { Name: 'retained_source_integrity', Status: 'Succeeded', CheckedFiles: 0, Failures: [] };
    manifest.Stages.push(stage);
    for (const artifact of extracted) {
      try {
        const file = inside(artifact.Path); const stat = await fs.lstat(file); const resolved = await fs.realpath(file);
        const samePath = process.platform === 'win32' ? resolved.toLowerCase() === file.toLowerCase() : resolved === file;
        if (!stat.isFile() || stat.isSymbolicLink() || !samePath || stat.size !== artifact.Bytes || await hashFile(file) !== artifact.SHA256) throw new Error('Retained source identity changed.');
      } catch (error) { stage.Failures.push({ Path: artifact.Path, Error: error.message }); }
      stage.CheckedFiles++;
    }
    manifest.RetainedSourcesUnchanged = stage.Failures.length === 0;
    if (!manifest.RetainedSourcesUnchanged) { stage.Status = 'Failed'; manifest.Error = 'Retained source files changed or became unavailable after analysis.'; limitation(manifest.Error); }
  }
  manifest.FinishedUtc = new Date().toISOString();
  manifest.Status = manifest.Error ? 'Failed' : manifest.Stages.some(stage => ['Failed', 'Unavailable', 'Skipped', 'Partial'].includes(stage.Status)) || (manifest.Format === 'native' && !manifest.Coverage.Complete) || (manifest.Format === 'javascript' && (!manifest.JavaScriptProviderCoverage || manifest.JavaScriptSelection?.Complete === false)) || ['unknown', 'java'].includes(manifest.Format) ? 'Partial' : 'Succeeded';
  await fs.writeFile(inside('rea-result.json'), json(manifest), { flag: 'wx' });
  process.stdout.write(JSON.stringify({ Status: manifest.Status, ManifestPath: inside('rea-result.json'), Stages: manifest.Stages.length, DecompiledFunctions: manifest.Coverage.DecompiledFunctions }) + '\n');
  if (manifest.Status === 'Failed') process.exitCode = 1;
}
