// Admit only a retained, identity-matched local PDB. Disable implicit symbol-server lookup.
// @category ExecutableAnalysis
import ghidra.app.util.headless.HeadlessScript;
import ghidra.app.plugin.core.analysis.PdbUniversalAnalyzer;
import ghidra.app.util.pdb.PdbProgramAttributes;
import ghidra.app.util.bin.format.pdb2.pdbreader.*;
import ghidra.program.model.listing.Program;
import com.google.gson.Gson;
import com.google.gson.JsonParser;
import java.io.File;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.*;

public class PrepareProgram extends HeadlessScript {
    @Override protected void run() throws Exception {
        String[] args=getScriptArgs();
        if(args.length!=2)throw new IllegalArgumentException("PrepareProgram requires retained PDB and baseline-flow paths, or none.");
        if(!args[1].equals("none")) {
            File baseline=new File(args[1]);if(!baseline.isAbsolute()||baseline.length()>1048576)throw new IllegalArgumentException("Invalid baseline-flow file.");
            String text=Files.readString(baseline.toPath());var data=JsonParser.parseString(text).getAsJsonObject();
            if(!data.get("SourceSHA256").getAsString().equalsIgnoreCase(currentProgram.getExecutableSHA256())||data.getAsJsonArray("Sites").size()>2048)throw new IllegalArgumentException("Baseline-flow identity/bound mismatch.");
            currentProgram.getOptions(Program.PROGRAM_INFO).setString("ExecutableAnalysis baseline terminal sites",text);
        }
        Map<String,String> options=getCurrentAnalysisOptionsAndValues(currentProgram);
        for(String name:List.of("PDB Universal","PDB"))if(options.containsKey(name))setAnalysisOption(currentProgram,name,"false");
        Map<String,Object> result=new LinkedHashMap<>();result.put("Status","NoRetainedCompanion");result.put("NetworkLookup",false);
        try {
            if(!args[0].equals("none")) {
                File file=new File(args[0]);
                if(!file.isAbsolute()||!file.isFile()||file.length()>1073741824L)throw new IllegalArgumentException("PDB is not a bounded local file.");
                PdbProgramAttributes attributes=new PdbProgramAttributes(currentProgram);
                try(AbstractPdb pdb=PdbParser.parse(file,new PdbReaderOptions(),monitor)) {
                    PdbIdentifiers id=pdb.getIdentifiers();
                    String expected=attributes.getPdbGuid();
                    if(expected==null||!id.getGuid().toString().replace("-","").equalsIgnoreCase(expected.replace("-",""))||id.getAge()!=attributes.getPdbAgeAsInt())throw new IllegalArgumentException("PDB GUID/age mismatch.");
                    result.put("Guid",id.getGuid().toString());result.put("Age",id.getAge());
                }
                byte[] digest=MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(file.toPath()));StringBuilder hex=new StringBuilder();for(byte b:digest)hex.append(String.format("%02x",b&255));
                result.put("SHA256",hex.toString());result.put("File",file.getName());result.put("IdentityMatched",true);
                PdbUniversalAnalyzer.setPdbFileOption(currentProgram,file);setAnalysisOption(currentProgram,"PDB Universal","true");result.put("Status","Matched");
            }
        }catch(Exception error){result.put("Status","Failed");result.put("Error",error.toString());throw error;}
        finally{currentProgram.getOptions(Program.PROGRAM_INFO).setString("ExecutableAnalysis PDB preparation",new Gson().toJson(result));}
    }
}
