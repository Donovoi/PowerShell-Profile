// Bounded instruction/flow observations. This helper never changes listing bytes or flow overrides.
import ghidra.program.model.listing.*;
import ghidra.program.model.address.Address;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.pcode.PcodeOp;
import ghidra.util.task.TaskMonitor;
import java.util.*;
import com.google.gson.JsonParser;

public final class NativeRecovery {
    private final Program program;
    private final TaskMonitor monitor;
    private final long deadline;
    private final List<Map<String,Object>> sites=new ArrayList<>();
    private final List<Map<String,Object>> modeledNoReturn=new ArrayList<>();
    private long instructions=0;
    private int inspected=0;
    private boolean complete=true;
    private final Set<String> requested=new LinkedHashSet<>();
    private final Set<String> seen=new HashSet<>();
    public NativeRecovery(Program program,TaskMonitor monitor,long deadline){this.program=program;this.monitor=monitor;this.deadline=deadline;String baseline=program.getOptions(Program.PROGRAM_INFO).getString("ExecutableAnalysis baseline terminal sites",null);if(baseline!=null)for(var site:JsonParser.parseString(baseline).getAsJsonObject().getAsJsonArray("Sites"))requested.add(site.getAsString().toLowerCase());}
    private Map<String,Object> row(Object... pairs){Map<String,Object> value=new LinkedHashMap<>();for(int i=0;i<pairs.length;i+=2)value.put((String)pairs[i],pairs[i+1]);return value;}
    private String canonical(Address value){return value==null?null:"0x"+Long.toUnsignedString(value.getOffset(),16);}
    private String hex(byte[] bytes){StringBuilder out=new StringBuilder();for(byte b:bytes)out.append(String.format("%02x",b&255));return out.toString();}
    public Map<String,Object> inspect(Function function,String relativePath) throws Exception {
        StringBuilder assembly=new StringBuilder();boolean bodyComplete=true;
        InstructionIterator iterator=program.getListing().getInstructions(function.getBody(),true);
        while(iterator.hasNext()){
            monitor.checkCancelled();
            if(System.nanoTime()>=deadline||instructions>=1000000||assembly.length()>=8388608){bodyComplete=false;complete=false;break;}
            Instruction instruction=iterator.next();instructions++;
            assembly.append(canonical(instruction.getAddress())).append(": ").append(instruction).append('\n');
            String site=canonical(instruction.getAddress());
            if(!requested.contains(site)&&(!instruction.getFlowType().isCall()||!instruction.getFlowType().isTerminal()))continue;
            boolean established=false;
            for(Address target:instruction.getFlows()){Function callee=program.getFunctionManager().getFunctionAt(target);if(callee!=null&&callee.hasNoReturn())established=true;}
            if(established&&!requested.contains(site)){
                if(modeledNoReturn.size()<2048)modeledNoReturn.add(row("Site",site,"Instruction",instruction.toString(),"Basis","Ghidra FunctionManager no-return flag; recorded model, not independently verified runtime behavior."));else complete=false;
                continue;
            }
            if(sites.size()>=2048){complete=false;continue;}
            byte[] bytes=instruction.getBytes();boolean jump=false,call=false,conditional=false;
            for(PcodeOp op:instruction.getPcode(false)){jump|=op.getOpcode()==PcodeOp.BRANCH||op.getOpcode()==PcodeOp.BRANCHIND;call|=op.getOpcode()==PcodeOp.CALL||op.getOpcode()==PcodeOp.CALLIND;conditional|=op.getOpcode()==PcodeOp.CBRANCH;}
            boolean tail=jump&&!call&&!conditional;
            boolean trap=program.getLanguage().getProcessor().toString().equalsIgnoreCase("x86")&&bytes.length==1&&(bytes[0]&255)==0xcc&&instruction.getMnemonicString().equalsIgnoreCase("INT3");
            List<String> targets=new ArrayList<>(),names=new ArrayList<>();
            for(Address target:instruction.getFlows()){targets.add(canonical(target));Function callee=program.getFunctionManager().getFunctionAt(target);names.add(callee==null?null:callee.getName(true));}
            Address next=instruction.getAddress().add(instruction.getLength());List<Map<String,Object>> incoming=new ArrayList<>();
            for(Reference reference:program.getReferenceManager().getReferencesTo(next)){if(incoming.size()>=16)break;incoming.add(row("From",canonical(reference.getFromAddress()),"Type",reference.getReferenceType().toString()));}
            seen.add(site);
            sites.add(row("Site",site,"Procedure",canonical(function.getEntryPoint()),"Name",function.getName(true),"Instruction",instruction.toString(),"Bytes",hex(bytes),"FlowType",instruction.getFlowType().toString(),"Override",instruction.getFlowOverride().name(),"Kind",tail?"TailJump":trap?"Breakpoint":"UnresolvedTerminalCall","Resolved",tail||trap,"Reason",tail?"Decoded unconditional branch; no-return callee assumption is unnecessary. The actual Ghidra override is recorded separately.":trap?"INT3 breakpoint/trap, not an unidentified ordinary callee. Resuming through a debugger is distinct from ordinary call return.":"Terminal call needs additional callee/no-return evidence.","Targets",targets,"TargetNames",names,"NextAddress",canonical(next),"NextByteInsideOwner",function.getBody().contains(next),"ReferencesToNextInstruction",incoming,"InstructionsPath",relativePath));
        }
        inspected++;
        return row("Text",assembly.toString(),"Complete",bodyComplete);
    }
    public Map<String,Object> summary(int discovered){
        long unresolved=sites.stream().filter(x->!Boolean.TRUE.equals(x.get("Resolved"))).count();
        List<String> missing=new ArrayList<>(requested);missing.removeAll(seen);
        return row("Scope","Terminal calls without an established model basis, plus requested baseline warning sites","Complete",complete&&inspected==discovered&&missing.isEmpty(),"InspectedFunctions",inspected,"ScannedInstructions",instructions,"SiteLimit",2048,"InstructionLimit",1000000,"BaselineSitesRequested",requested.size(),"MissingBaselineSites",missing,"ExistingNoReturnModelSites",modeledNoReturn,"TotalSites",sites.size(),"ResolvedSites",sites.size()-unresolved,"UnresolvedSites",unresolved,"TailJumps",sites.stream().filter(x->"TailJump".equals(x.get("Kind"))).count(),"Breakpoints",sites.stream().filter(x->"Breakpoint".equals(x.get("Kind"))).count(),"Sites",sites);
    }
    public String classifyHeaderPadding(Address source,Address target) {
        try{
            if(!program.getLanguage().getProcessor().toString().equalsIgnoreCase("x86"))return null;
            var memory=program.getMemory();Address base=program.getImageBase();
            if(memory.getShort(base)!=(short)0x5a4d)return null;
            long pe=Integer.toUnsignedLong(memory.getInt(base.add(60)));if(pe>16777216||memory.getInt(base.add(pe))!=0x4550)return null;
            int count=Short.toUnsignedInt(memory.getShort(base.add(pe+6))),size=Short.toUnsignedInt(memory.getShort(base.add(pe+20)));if(count>96||size>4096)return null;
            Address optional=base.add(pe+24);String field=null;Set<Address> allowed=new HashSet<>();
            if(target.equals(base.add(Integer.toUnsignedLong(memory.getInt(optional.add(20))))))allowed.add(optional.add(20));
            if(source.equals(optional.add(20)))field="OptionalHeader.BaseOfCode";
            for(int i=0;i<count;i++){Address header=optional.add(size+i*40L);if(target.equals(base.add(Integer.toUnsignedLong(memory.getInt(header.add(12))))))allowed.add(header.add(12));if(source.equals(header.add(12)))field="Section.VirtualAddress";}
            if(field==null||!target.equals(base.add(Integer.toUnsignedLong(memory.getInt(source)))))return null;
            int references=0;for(Reference reference:program.getReferenceManager().getReferencesTo(target)){if(++references>256||!allowed.contains(reference.getFromAddress()))return null;}
            MemoryBlock block=memory.getBlock(target);if(block==null||!target.equals(block.getStart()))return null;
            FunctionIterator functions=program.getFunctionManager().getFunctions(target,true);if(!functions.hasNext())return null;
            Address next=functions.next().getEntryPoint();long length=next.subtract(target);if(length<1||length>256||!block.equals(memory.getBlock(next)))return null;
            for(int i=0;i<length;i++)if((memory.getByte(target.add(i))&255)!=0xcc)return null;
            return field+" references section-start INT3 padding; the following function at "+canonical(next)+" is already recovered.";
        }catch(Exception error){return null;}
    }
}
