-- Conservative CFG liveness and register allocation for the semantic IR.
-- Contiguous native-call argument windows are allocated as a single group.
local specs=require('src.instructions').specs
local M={}

local function access(ins,slots)
    local spec=assert(specs[ins.op],'unknown optimizer opcode '..tostring(ins.op))
    local reads,writes={},{}
    for _,position in ipairs(slots and spec.slotReads or spec.reads) do reads[ins[position]]=true end
    for _,position in ipairs(slots and spec.slotWrites or spec.writes) do writes[ins[position]]=true end
    if spec.range and not slots then
        local first,count=ins[spec.range.first],ins[spec.range.count]
        for register=first,first+count-1 do reads[register]=true end
    end
    if spec.writeRange and not slots then
        local first=ins[spec.writeRange.first]
        for register=first,first+spec.writeRange.size-1 do writes[register]=true end
    end
    return reads,writes
end

local function copy(ins)
    return {op=ins.op,ins[1] or 0,ins[2] or 0,ins[3] or 0,ins[4] or 0,line=ins.line}
end

local function updateLines(proto)
    proto.lines={}
    for pc,ins in ipairs(proto.code) do proto.lines[pc]=ins.line or 1 end
end

local function fuseLoads(proto)
    local uses,definitions,targets={},{},{}
    for _,ins in ipairs(proto.code) do
        local reads,writes=access(ins)
        for register in pairs(reads) do uses[register]=(uses[register] or 0)+1 end
        for register in pairs(writes) do definitions[register]=(definitions[register] or 0)+1 end
        local branch=specs[ins.op].branch
        if branch then targets[ins[branch]]=true end
    end
    local output,remap,fused={}, {},0
    local pc=1
    while pc<=#proto.code do
        local ins,nextIns=proto.code[pc],proto.code[pc+1]
        remap[pc]=#output+1
        if ins.op=='LOADK' and nextIns and (nextIns.op=='NEWLOCAL' or nextIns.op=='NEWLOCAL1')
            and nextIns[2]==ins[1] and uses[ins[1]]==1 and definitions[ins[1]]==1
            and not targets[pc+1] then
            output[#output+1]={op=nextIns.op=='NEWLOCAL' and 'LOADLOCALC' or 'LOADLOCAL',
                nextIns[1],ins[2],0,0,line=nextIns.line or ins.line}
            remap[pc+1]=#output
            fused=fused+1; pc=pc+2
        else output[#output+1]=copy(ins); pc=pc+1 end
    end
    for _,ins in ipairs(output) do
        local branch=specs[ins.op].branch
        if branch then ins[branch]=assert(remap[ins[branch]],'unmapped optimizer branch') end
    end
    proto.code=output
    updateLines(proto)
    return fused
end

local function liveness(proto,slots)
    local code=proto.code
    local leaders={[1]=true}
    for pc,ins in ipairs(code) do
        local spec=specs[ins.op]
        if spec.branch then leaders[ins[spec.branch]]=true end
        if (spec.branch or spec.terminal) and pc<#code then leaders[pc+1]=true end
    end
    local starts={}
    for pc in pairs(leaders) do starts[#starts+1]=pc end
    table.sort(starts)
    local blocks,owner={},{}
    for index,first in ipairs(starts) do
        local last=(starts[index+1] or (#code+1))-1
        local block={first=first,last=last,uses={},defs={},liveIn={},liveOut={},successors={}}
        blocks[index]=block
        for pc=first,last do
            owner[pc]=index
            local reads,writes=access(code[pc],slots)
            for register in pairs(reads) do
                if not block.defs[register] then block.uses[register]=true end
            end
            for register in pairs(writes) do block.defs[register]=true end
        end
    end
    for index,block in ipairs(blocks) do
        local ins=code[block.last]; local spec=specs[ins.op]
        if spec.branch then block.successors[#block.successors+1]=assert(owner[ins[spec.branch]]) end
        if not spec.terminal and not spec.unconditional and blocks[index+1] then
            block.successors[#block.successors+1]=index+1
        end
    end
    -- The monotone iteration handles both back edges and joins. Block-level
    -- sets avoid a full live-register set for every bytecode instruction.
    local changed=true
    while changed do
        changed=false
        for index=#blocks,1,-1 do
            local block=blocks[index]
            for _,successor in ipairs(block.successors) do
                for register in pairs(blocks[successor].liveIn) do
                    if not block.liveOut[register] then block.liveOut[register]=true; changed=true end
                end
            end
            for register in pairs(block.uses) do
                if not block.liveIn[register] then block.liveIn[register]=true; changed=true end
            end
            for register in pairs(block.liveOut) do
                if not block.defs[register] and not block.liveIn[register] then
                    block.liveIn[register]=true; changed=true
                end
            end
        end
    end
    local intervals={}
    local function touch(register,pc)
        local interval=intervals[register]
        if not interval then intervals[register]={first=pc,last=pc}
        else interval.first=math.min(interval.first,pc); interval.last=math.max(interval.last,pc) end
    end
    for pc,ins in ipairs(code) do
        local reads,writes=access(ins,slots)
        for register in pairs(reads) do touch(register,pc) end
        for register in pairs(writes) do touch(register,pc) end
    end
    for _,block in ipairs(blocks) do
        for register in pairs(block.liveIn) do touch(register,block.first) end
        for register in pairs(block.liveOut) do touch(register,block.last) end
    end
    if slots then
        -- All parameters initialize before instruction 1. Even unused params
        -- must stay distinct during that initialization and retain their order.
        for _,slot in ipairs(proto.params) do touch(slot,0) end
    end
    return intervals,#blocks
end

local function allocateSlots(proto)
    local intervals=liveness(proto,true)
    local nodes,occupied,remap={}, {},{}
    local maximum=0
    for slot=1,proto.slots do
        if proto.boxed[slot] then
            -- Keep captured cells at their original IDs, including all parent
            -- indices stored in child upvalue descriptors.
            occupied[slot]=true; remap[slot]=slot; maximum=math.max(maximum,slot)
        elseif intervals[slot] then
            local interval=intervals[slot]
            nodes[#nodes+1]={slot=slot,first=interval.first,last=interval.last}
        end
    end
    table.sort(nodes,function(a,b) return a.first<b.first or (a.first==b.first and a.slot<b.slot) end)
    local active={}
    for _,node in ipairs(nodes) do
        for index=#active,1,-1 do
            local other=active[index]
            if other.last<node.first then occupied[other.physical]=nil; table.remove(active,index) end
        end
        local physical=1
        while occupied[physical] do physical=physical+1 end
        node.physical=physical; occupied[physical]=true; remap[node.slot]=physical
        maximum=math.max(maximum,physical); active[#active+1]=node
    end
    for _,ins in ipairs(proto.code) do
        local spec=specs[ins.op]; local positions={}
        for _,position in ipairs(spec.slotReads) do positions[position]=true end
        for _,position in ipairs(spec.slotWrites) do positions[position]=true end
        for position in pairs(positions) do ins[position]=assert(remap[ins[position]],'missing local-slot allocation') end
    end
    for index,slot in ipairs(proto.params) do proto.params[index]=assert(remap[slot],'missing parameter-slot allocation') end
    local boxed={}
    for slot=1,maximum do boxed[slot]=false end
    for slot,value in pairs(proto.boxed) do if value then boxed[slot]=true end end
    proto.boxed=boxed; proto.slots=maximum
end

local function allocate(proto)
    local intervals,blockCount=liveness(proto)
    local ranges={}
    for _,ins in ipairs(proto.code) do
        local range=specs[ins.op].range
        if range and ins[range.count]>0 then
            ranges[#ranges+1]={first=ins[range.first],last=ins[range.first]+ins[range.count]-1}
        end
        local result=specs[ins.op].writeRange
        if result then ranges[#ranges+1]={first=ins[result.first],last=ins[result.first]+result.size-1} end
    end
    table.sort(ranges,function(a,b) return a.first<b.first or (a.first==b.first and a.last<b.last) end)
    local groups={}
    for _,range in ipairs(ranges) do
        local previous=groups[#groups]
        if previous and range.first<=previous.lastRegister then
            previous.lastRegister=math.max(previous.lastRegister,range.last)
        else groups[#groups+1]={firstRegister=range.first,lastRegister=range.last} end
    end
    local grouped,nodes={},{}
    for _,group in ipairs(groups) do
        group.first,group.last=math.huge,0
        for register=group.firstRegister,group.lastRegister do
            grouped[register]=true
            local interval=assert(intervals[register],'argument register without an interval')
            group.first=math.min(group.first,interval.first); group.last=math.max(group.last,interval.last)
        end
        group.count=group.lastRegister-group.firstRegister+1
        nodes[#nodes+1]=group
    end
    for register,interval in pairs(intervals) do
        if not grouped[register] then
            nodes[#nodes+1]={firstRegister=register,lastRegister=register,count=1,
                first=interval.first,last=interval.last}
        end
    end
    table.sort(nodes,function(a,b)
        return a.first<b.first or (a.first==b.first and a.firstRegister<b.firstRegister)
    end)
    local active,occupied,remap={}, {},{}
    local maximum=0
    for _,node in ipairs(nodes) do
        for index=#active,1,-1 do
            local other=active[index]
            -- Keep operands distinct within an instruction, including handlers
            -- such as FORPREP that read and write operands one at a time.
            if other.last<node.first then
                for register=other.physical,other.physical+other.count-1 do occupied[register]=nil end
                table.remove(active,index)
            end
        end
        local physical=1
        while true do
            local conflict
            for register=physical,physical+node.count-1 do
                if occupied[register] then conflict=register; break end
            end
            if not conflict then break end
            physical=conflict+1
        end
        node.physical=physical
        for offset=0,node.count-1 do
            occupied[physical+offset]=true; remap[node.firstRegister+offset]=physical+offset
        end
        maximum=math.max(maximum,physical+node.count-1)
        active[#active+1]=node
    end
    for _,ins in ipairs(proto.code) do
        local spec=specs[ins.op]
        local positions={}
        for _,position in ipairs(spec.reads) do positions[position]=true end
        for _,position in ipairs(spec.writes) do positions[position]=true end
        if spec.range and ins[spec.range.count]>0 then positions[spec.range.first]=true end
        if spec.writeRange then positions[spec.writeRange.first]=true end
        for position in pairs(positions) do ins[position]=assert(remap[ins[position]],'missing register allocation') end
    end
    proto.registers=maximum
    return blockCount
end

function M.apply(root,options)
    options=options or {}
    local enabled=options.enabled~=false and options.optimize~=false
    local stats={prototypes=0,instructionsBefore=0,instructionsAfter=0,registersBefore=0,
        registersAfter=0,slotsBefore=0,slotsAfter=0,boxedSlots=0,unboxedSlots=0,
        fusedLoadLocals=0,fixedCalls=0,fixedResults=0,blocks=0}
    local function optimize(proto)
        stats.prototypes=stats.prototypes+1
        stats.instructionsBefore=stats.instructionsBefore+#proto.code
        stats.registersBefore=stats.registersBefore+proto.registers
        stats.slotsBefore=stats.slotsBefore+proto.slots
        local captured=proto.captured or {}
        if not proto.captured then
            for slot,value in pairs(proto.boxed or {}) do if value then captured[slot]=true end end
            for _,child in ipairs(proto.children) do
                for _,up in ipairs(child.upvalues) do if up.kind=='local' then captured[up.index]=true end end
            end
            proto.captured=captured
        end
        proto.boxed={}
        for slot=1,proto.slots do
            proto.boxed[slot]=captured[slot] or not enabled or options.unbox==false
        end
        for _,ins in ipairs(proto.code) do
            if ins.op=='GETLOCAL' or ins.op=='GETLOCAL1' then
                ins.op=proto.boxed[ins[2]] and 'GETLOCAL' or 'GETLOCAL1'
            elseif ins.op=='NEWLOCAL' or ins.op=='NEWLOCAL1' then
                ins.op=proto.boxed[ins[1]] and 'NEWLOCAL' or 'NEWLOCAL1'
            elseif ins.op=='SETLOCAL' or ins.op=='SETLOCAL1' then
                ins.op=proto.boxed[ins[1]] and 'SETLOCAL' or 'SETLOCAL1'
            elseif ins.op=='LOADLOCAL' or ins.op=='LOADLOCALC' then
                ins.op=proto.boxed[ins[1]] and 'LOADLOCALC' or 'LOADLOCAL'
            end
        end
        proto.localsOptimized=true
        if enabled and options.fuse~=false then stats.fusedLoadLocals=stats.fusedLoadLocals+fuseLoads(proto) end
        if enabled and options.reuse~=false then
            stats.blocks=stats.blocks+allocate(proto)
            allocateSlots(proto)
        end
        for _,ins in ipairs(proto.code) do
            if specs[ins.op].range and not specs[ins.op].guardTuple then stats.fixedCalls=stats.fixedCalls+1 end
            if specs[ins.op].writeRange then stats.fixedResults=stats.fixedResults+1 end
        end
        stats.instructionsAfter=stats.instructionsAfter+#proto.code
        stats.registersAfter=stats.registersAfter+proto.registers
        stats.slotsAfter=stats.slotsAfter+proto.slots
        for slot=1,proto.slots do
            local key=proto.boxed[slot] and 'boxedSlots' or 'unboxedSlots'
            stats[key]=stats[key]+1
        end
        updateLines(proto)
        for _,child in ipairs(proto.children) do optimize(child) end
    end
    optimize(root)
    stats.instructionsSaved=stats.instructionsBefore-stats.instructionsAfter
    stats.registersSaved=stats.registersBefore-stats.registersAfter
    stats.slotsSaved=stats.slotsBefore-stats.slotsAfter
    return stats
end

return M
