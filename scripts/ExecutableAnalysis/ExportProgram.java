// Export static program evidence from an owned, read-only headless Ghidra import.
// @category ExecutableAnalysis
import ghidra.app.util.headless.HeadlessScript;
import ghidra.framework.Application;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressIterator;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonParser;
import ghidra.app.util.pdb.PdbProgramAttributes;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public class ExportProgram extends HeadlessScript {
    private static final int ROW_LIMIT = 100000;
    private static final long CODE_BYTE_LIMIT = 536870912L;
    private static final int TEXT_BYTE_LIMIT = 16777216;
    private final List<String> limitations = new ArrayList<>();
    private long codeBytes = 0;
    private long metadataCharacters = 0;

    private Map<String, Object> row(Object... pairs) {
        Map<String, Object> value = new LinkedHashMap<>();
        for (int index = 0; index < pairs.length; index += 2) value.put((String)pairs[index], pairs[index + 1]);
        return value;
    }

    private String sha256(byte[] bytes) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
        StringBuilder result = new StringBuilder();
        for (byte value : digest) result.append(String.format("%02x", value & 0xff));
        return result.toString();
    }

    private void writeJson(Path file, Object value) throws Exception {
        String text = new GsonBuilder().setPrettyPrinting().serializeNulls().disableHtmlEscaping().create().toJson(value) + "\n";
        Files.writeString(file, text, StandardCharsets.UTF_8, StandardOpenOption.CREATE_NEW);
    }

    @Override
    protected void run() throws Exception {
        String[] arguments = getScriptArgs();
        if (arguments.length < 3 || arguments.length > 5) throw new IllegalArgumentException("Usage: ExportProgram.java ABSENT_OUTPUT_DIRECTORY MAX_FUNCTIONS TIMEOUT_SECONDS [TOTAL_SECONDS [WORKFLOW_DEADLINE_UNIX_MILLISECONDS]]");
        Path output = Path.of(arguments[0]);
        if (!output.isAbsolute()) throw new IllegalArgumentException("Output directory must be absolute.");
        int maxFunctions = Integer.parseInt(arguments[1]);
        int functionTimeout = Integer.parseInt(arguments[2]);
        int totalSeconds = arguments.length >= 4 ? Integer.parseInt(arguments[3]) : 3600;
        Long workflowDeadline = arguments.length == 5 ? Long.parseLong(arguments[4]) : null;
        if (maxFunctions < 0 || functionTimeout < 1 || functionTimeout > 86400 || totalSeconds < 1 || totalSeconds > 86400) throw new IllegalArgumentException("Invalid analysis budget.");
        Files.createDirectory(output);
        Path code = Files.createDirectory(output.resolve("code"));
        Path instructionsDirectory = Files.createDirectory(output.resolve("instructions"));
        long deadline = System.nanoTime() + totalSeconds * 1000000000L;
        if (workflowDeadline != null) {
            if (workflowDeadline < 1) throw new IllegalArgumentException("Invalid workflow deadline.");
            long remainingMillis = Math.max(0L, workflowDeadline - System.currentTimeMillis());
            deadline = Math.min(deadline, System.nanoTime() + Math.min(remainingMillis, 86400000L) * 1000000L);
        }
        Boolean analysisTimedOut = isRunningHeadless() ? analysisTimeoutOccurred() : null;
        if (!Boolean.FALSE.equals(analysisTimedOut)) limitations.add("Auto-analysis timed out or its timeout status is unknown. Discovered functions do not establish a complete function inventory.");
        Map<String, Object> result = row("SchemaVersion", 1, "StartedUtc", Instant.now().toString(), "Status", "Running", "TargetExecuted", false,
            "Provider", "Ghidra", "ProviderVersion", Application.getApplicationVersion(),
            "Name", currentProgram.getName(), "ExecutablePath", currentProgram.getExecutablePath(), "ExecutableSHA256", currentProgram.getExecutableSHA256(),
            "Language", currentProgram.getLanguageID().toString(), "CompilerSpec", currentProgram.getCompilerSpec().getCompilerSpecID().toString(),
            "ImageBase", currentProgram.getImageBase().toString(), "FunctionLimit", maxFunctions == 0 ? null : maxFunctions,
            "PerFunctionTimeoutSeconds", functionTimeout, "TotalTimeoutSeconds", totalSeconds, "WorkflowDeadlineUnixMilliseconds", workflowDeadline,
            "AutoAnalysis", row("TimedOut", analysisTimedOut), "Limitations", limitations);
        List<Map<String, Object>> functions = new ArrayList<>();
        List<Map<String, Object>> imports = new ArrayList<>();
        List<Map<String, Object>> exports = new ArrayList<>();
        List<Map<String, Object>> strings = new ArrayList<>();
        int discovered = 0, attempted = 0, succeeded = 0, failed = 0, external = 0;
        boolean truncated = false;
        boolean referenceScanComplete = false;
        int referencesScanned = 0;
        Map<String, Map<String, Object>> codeReferenceGaps = new LinkedHashMap<>();
        DecompInterface decompiler = new DecompInterface();
        NativeRecovery recovery = new NativeRecovery(currentProgram, monitor, deadline);
        try {
            SymbolIterator importSymbols = currentProgram.getSymbolTable().getExternalSymbols();
            while (importSymbols.hasNext()) {
                monitor.checkCancelled();
                if (System.nanoTime() >= deadline) { truncated = true; break; }
                if (imports.size() >= ROW_LIMIT) { limitations.add("Import symbols exceed the 100000-row bound."); truncated = true; break; }
                Symbol symbol = importSymbols.next();
                String name = symbol.getName(true);
                metadataCharacters += name.length();
                if (metadataCharacters > TEXT_BYTE_LIMIT) { limitations.add("Metadata text exceeds the 16-million-character bound."); truncated = true; break; }
                imports.add(row("Name", name, "Address", symbol.getAddress().toString(), "Type", symbol.getSymbolType().toString()));
            }
            AddressIterator exportAddresses = currentProgram.getSymbolTable().getExternalEntryPointIterator();
            while (exportAddresses.hasNext()) {
                monitor.checkCancelled();
                if (System.nanoTime() >= deadline) { truncated = true; break; }
                if (exports.size() >= ROW_LIMIT) { limitations.add("Export entries exceed the 100000-row bound."); truncated = true; break; }
                Address address = exportAddresses.next();
                Symbol symbol = currentProgram.getSymbolTable().getPrimarySymbol(address);
                String name = symbol == null ? null : symbol.getName(true);
                metadataCharacters += name == null ? 0 : name.length();
                if (metadataCharacters > TEXT_BYTE_LIMIT) { truncated = true; break; }
                exports.add(row("Address", address.toString(), "Name", name));
            }
            DataIterator data = currentProgram.getListing().getDefinedData(true);
            while (data.hasNext()) {
                monitor.checkCancelled();
                if (System.nanoTime() >= deadline) { truncated = true; break; }
                Data value = data.next();
                if (!value.hasStringValue()) continue;
                if (strings.size() >= ROW_LIMIT) { limitations.add("Defined strings exceed the 100000-row bound."); truncated = true; break; }
                String text = String.valueOf(value.getValue());
                if (text.length() > 262144) { text = text.substring(0, 262144); limitations.add("At least one defined string exceeded 262144 UTF-16 code units and was explicitly truncated."); truncated = true; }
                metadataCharacters += text.length();
                if (metadataCharacters > TEXT_BYTE_LIMIT) { limitations.add("Metadata text exceeds the 16-million-character bound."); truncated = true; break; }
                strings.add(row("Address", value.getAddress().toString(), "Length", value.getLength(), "Type", value.getDataType().getName(), "Value", text));
            }
            if (!decompiler.openProgram(currentProgram)) throw new IllegalStateException("Decompiler could not open the imported program: " + decompiler.getLastMessage());
            FunctionIterator iterator = currentProgram.getFunctionManager().getFunctions(true);
            while (iterator.hasNext()) {
                monitor.checkCancelled();
                Function function = iterator.next();
                discovered++;
                if (function.isExternal()) { external++; continue; }
                if ((maxFunctions > 0 && attempted >= maxFunctions) || attempted >= ROW_LIMIT || System.nanoTime() >= deadline || codeBytes >= CODE_BYTE_LIMIT) { truncated = true; continue; }
                attempted++;
                String functionName = function.getName(true);
                if (functionName.length() > 4096) { functionName = functionName.substring(0, 4096); truncated = true; }
                Map<String, Object> item = row("Address", function.getEntryPoint().toString(), "Name", functionName, "Thunk", function.isThunk(), "Status", "Pending");
                functions.add(item);
                try {
                    String instructionName=String.format("%06d-%s.asm",attempted,function.getEntryPoint().toString().replaceAll("[^a-zA-Z0-9_-]","_"));
                    Map<String,Object> nativeBody=recovery.inspect(function,"instructions/"+instructionName);
                    byte[] instructionBytes=((String)nativeBody.get("Text")).getBytes(StandardCharsets.UTF_8);
                    if(instructionBytes.length>TEXT_BYTE_LIMIT||codeBytes+instructionBytes.length>CODE_BYTE_LIMIT)throw new IllegalStateException("Native instructions exceeded the retained byte budget.");
                    Files.write(instructionsDirectory.resolve(instructionName),instructionBytes,StandardOpenOption.CREATE_NEW);codeBytes+=instructionBytes.length;
                    item.put("InstructionsPath","instructions/"+instructionName);item.put("InstructionsBytes",instructionBytes.length);item.put("InstructionsSHA256",sha256(instructionBytes));item.put("InstructionsComplete",nativeBody.get("Complete"));
                }catch(Exception error){truncated=true;item.put("InstructionsError",error.toString());}
                try {
                    int remainingSeconds = (int)Math.max(1L, (deadline - System.nanoTime()) / 1000000000L);
                    DecompileResults decompiled = decompiler.decompileFunction(function, Math.min(functionTimeout, remainingSeconds), monitor);
                    if (!decompiled.decompileCompleted() || decompiled.getDecompiledFunction() == null) throw new IllegalStateException(decompiled.getErrorMessage());
                    byte[] bytes = decompiled.getDecompiledFunction().getC().getBytes(StandardCharsets.UTF_8);
                    if (bytes.length > TEXT_BYTE_LIMIT || codeBytes + bytes.length > CODE_BYTE_LIMIT) throw new IllegalStateException("Recovered code exceeds the 16 MiB per-file or 512 MiB total bound.");
                    String filename = String.format("%06d-%s.c", attempted, function.getEntryPoint().toString().replaceAll("[^a-zA-Z0-9_-]", "_"));
                    Files.write(code.resolve(filename), bytes, StandardOpenOption.CREATE_NEW);
                    codeBytes += bytes.length;
                    item.put("Status", "Succeeded"); item.put("Path", "code/" + filename); item.put("Bytes", bytes.length); item.put("SHA256", sha256(bytes));
                    succeeded++;
                } catch (Exception error) { failed++; item.put("Status", "Failed"); item.put("Error", error.toString()); }
            }
            result.put("Status", failed > 0 || truncated || !Boolean.FALSE.equals(analysisTimedOut) ? "Partial" : "Succeeded");
        } catch (Exception error) { result.put("Status", "Failed"); result.put("Error", error.toString()); }
        finally {
            decompiler.dispose();
            // Data pointers can reach callbacks that Ghidra disassembled but did
            // not define as functions. Inventory coverage must not hide them.
            try {
                ReferenceIterator references = currentProgram.getReferenceManager().getReferenceIterator(currentProgram.getMinAddress());
                while (references.hasNext()) {
                    monitor.checkCancelled();
                    if (referencesScanned >= 1000000 || codeReferenceGaps.size() >= 2048 || System.nanoTime() >= deadline) break;
                    Reference reference = references.next();
                    referencesScanned++;
                    if (!reference.getReferenceType().isData()) continue;
                    Address target = reference.getToAddress();
                    MemoryBlock block = currentProgram.getMemory().getBlock(target);
                    if (block == null || !block.isExecute() || currentProgram.getFunctionManager().getFunctionContaining(target) != null ||
                        currentProgram.getListing().getInstructionAt(target) == null) continue;
                    codeReferenceGaps.putIfAbsent(target.toString(), row("TargetAddress", target.toString(),
                        "FirstSourceAddress", reference.getFromAddress().toString(), "ReferenceType", reference.getReferenceType().toString()));
                }
                referenceScanComplete = !references.hasNext();
            } catch (Exception error) {
                limitations.add("Code-reference scan could not complete: " + error.getClass().getSimpleName());
            }
            if (!referenceScanComplete) {
                limitations.add("Code-reference scan stopped before completion; remaining referenced entry points are unknown.");
                if (!"Failed".equals(result.get("Status"))) result.put("Status", "Partial");
            }
            int unresolvedReferenceGaps=0;
            for(Map<String,Object> candidate:codeReferenceGaps.values()){
                Address source=toAddr((String)candidate.get("FirstSourceAddress")),target=toAddr((String)candidate.get("TargetAddress"));
                String resolution=recovery.classifyHeaderPadding(source,target);
                candidate.put("Resolved",resolution!=null);candidate.put("Resolution",resolution);
                if(resolution==null)unresolvedReferenceGaps++;
            }
            if (unresolvedReferenceGaps>0) {
                limitations.add("Data references reach executable instructions outside discovered functions. See code-reference-gaps.json; these are candidates, not verified function starts.");
                if (!"Failed".equals(result.get("Status"))) result.put("Status", "Partial");
            }
            if (truncated) limitations.add("A function, row, text, time or byte budget limited coverage; omitted data is unknown, not absent.");
            Map<String,Object> terminal=recovery.summary(discovered-external);
            if(!Boolean.TRUE.equals(terminal.get("Complete"))){limitations.add("Native instruction/terminal-flow inspection did not cover every discovered function or requested baseline site; see terminal-flow.json.");if(!"Failed".equals(result.get("Status")))result.put("Status","Partial");}
            if(((Number)terminal.get("UnresolvedSites")).longValue()>0)limitations.add("Some inspected terminal calls still lack a verified branch/trap or no-return basis; see terminal-flow.json for exact sites.");
            result.put("TerminalFlow",terminal);
            PdbProgramAttributes pdb=new PdbProgramAttributes(currentProgram);
            String preparation=currentProgram.getOptions(ghidra.program.model.listing.Program.PROGRAM_INFO).getString("ExecutableAnalysis PDB preparation",null);
            result.put("Pdb",row("Loaded",pdb.isPdbLoaded(),"File",pdb.getPdbFile(),"Guid",pdb.getPdbGuid(),"Age",pdb.getPdbAge(),"Preparation",preparation==null?null:JsonParser.parseString(preparation)));
            result.put("CodeInterpretation","Retained pseudocode is a reconstruction. Coverage is relative to the discovered function inventory; native instruction and symbol provenance are recorded separately.");
            result.put("FinishedUtc", Instant.now().toString());
            result.put("Coverage", row("Scope", "GhidraDiscoveredFunctions", "DiscoveredFunctions", discovered, "AttemptedFunctions", attempted, "DecompiledFunctions", succeeded, "FailedFunctions", failed, "ExternalFunctions", external,
                "UnrecoveredCodeReferenceCandidates", unresolvedReferenceGaps, "CodeReferenceScanComplete", referenceScanComplete,
                "Complete", Boolean.FALSE.equals(analysisTimedOut) && !truncated && failed == 0 && attempted + external == discovered && !"Failed".equals(result.get("Status"))));
            result.put("Functions", functions); result.put("CodeBytes", codeBytes);
            writeJson(output.resolve("imports.json"), imports);
            writeJson(output.resolve("exports.json"), exports);
            writeJson(output.resolve("strings.json"), strings);
            writeJson(output.resolve("terminal-flow.json"), terminal);
            writeJson(output.resolve("code-reference-gaps.json"), row("SchemaVersion", 1, "TargetExecuted", false,
                "ExecutableSHA256", currentProgram.getExecutableSHA256(), "ScanComplete", referenceScanComplete,
                "ReferencesScanned", referencesScanned, "ReferenceLimit", 1000000, "CandidateLimit", 2048,
                "CandidateCount", codeReferenceGaps.size(), "UnresolvedCandidateCount",unresolvedReferenceGaps,"Candidates", new ArrayList<>(codeReferenceGaps.values()),
                "Limitations", List.of("Only existing data references to executable instructions outside defined functions are considered. No code is executed or automatically reclassified.",
                    "An empty candidate list does not establish complete code discovery. Complete in Coverage refers only to the discovered function inventory.")));
            writeJson(output.resolve("ghidra-result.json"), result);
            println("ExecutableAnalysis export: " + result.get("Status") + "; " + succeeded + "/" + attempted + " functions decompiled.");
        }
    }
}
