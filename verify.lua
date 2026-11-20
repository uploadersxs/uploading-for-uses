-- Validate semantic IR before it is randomized or serialized.
local instructions=require('src.instructions')
local specs=instructions.specs
local M={}

local function integer(value, minimum, maximum)
    return type(value)=='number' and value==math.floor(value)
        and value>=minimum and value<=maximum
end

function M.check(root)
    local seen={}
    local function check(proto,parent,path)
        local function fail(message,pc)
            error(('IR %s%s: %s'):format(path,pc and (' instruction '..pc) or '',message),0)
        end
        if type(proto)~='table' then fail('prototype must be a table') end
        if seen[proto] then fail('prototype tree contains a cycle or shared child') end
        seen[proto]=true
        for _,key in ipairs({'code','constants','children','upvalues','params'}) do
            if type(proto[key])~='table' then fail(key..' must be a table') end
            local count=0
            for index in pairs(proto[key]) do
                if not integer(index,1,#proto[key]) then fail(key..' must be a dense array') end
                count=count+1
            end
            if count~=#proto[key] then fail(key..' must be a dense array') end
        end
        for _,key in ipairs({'slots','registers'}) do
            if not integer(proto[key],0,4294967295) then fail('invalid '..key..' count') end
        end
        if type(proto.vararg)~='boolean' then fail('vararg flag must be boolean') end
        if proto.localsOptimized then
            if type(proto.boxed)~='table' then fail('optimized local storage flags must be a table') end
            for slot=1,proto.slots do
                if type(proto.boxed[slot])~='boolean' then fail('missing local storage flag') end
            end
        end
        if #proto.code==0 then fail('empty instruction stream') end
        local parameterSlots={}
        for _,slot in ipairs(proto.params) do
            if not integer(slot,1,proto.slots) then fail('parameter slot out of range') end
            if parameterSlots[slot] then fail('duplicate parameter slot') end
            parameterSlots[slot]=true
        end
        for _,constant in ipairs(proto.constants) do
            if type(constant)~='table' then fail('constant must be a table') end
            local kind=constant.kind
            if kind=='nil' then
                if constant.value~=nil then fail('nil constant has a value') end
            elseif kind=='boolean' or kind=='number' or kind=='string' then
                if type(constant.value)~=kind then fail('invalid '..kind..' constant') end
            else fail('unknown constant kind '..tostring(kind)) end
        end
        for _,up in ipairs(proto.upvalues) do
            if not parent then fail('root prototype cannot capture upvalues') end
            if type(up)~='table' then fail('upvalue must be a table') end
            local limit=up.kind=='local' and parent.slots
                or up.kind=='upvalue' and #parent.upvalues
            if not limit or not integer(up.index,1,limit) then fail('upvalue capture out of range') end
            if up.kind=='local' and parent.localsOptimized and not parent.boxed[up.index] then
                fail('closure captures an unboxed local')
            end
        end
        for pc,ins in ipairs(proto.code) do
            if type(ins)~='table' then fail('instruction must be a table',pc) end
            local spec=specs[ins.op]
            if not spec then fail('unknown opcode '..tostring(ins.op),pc) end
            local used={}
            for _,field in ipairs(spec.fields) do used[instructions.positions[field]]=true end
            for position=1,4 do
                local value=ins[position]
                if used[position] and value==nil then fail('missing operand '..position,pc) end
                if value==nil then value=0 end
                if not integer(value,0,4294967295) then fail('invalid operand '..position,pc) end
                if not used[position] and value~=0 then fail('nonzero unused operand '..position,pc) end
            end
            local function indices(positions,limit,label)
                for _,position in ipairs(positions) do
                    if not integer(ins[position],1,limit) then fail(label..' operand out of range',pc) end
                end
            end
            indices(spec.reads,proto.registers,'register')
            indices(spec.writes,proto.registers,'register')
            indices(spec.slotReads,proto.slots,'local slot')
            indices(spec.slotWrites,proto.slots,'local slot')
            indices(spec.constant,#proto.constants,'constant')
            indices(spec.child,#proto.children,'child')
            indices(spec.upvalue,#proto.upvalues,'upvalue')
            if spec.branch and not integer(ins[spec.branch],1,#proto.code) then
                fail('branch target out of range',pc)
            end
            if pc==#proto.code and not spec.terminal and not spec.unconditional then
                fail('instruction stream can fall through its end',pc)
            end
            if spec.range then
                local first,count=ins[spec.range.first],ins[spec.range.count]
                if count==0 then
                    if first~=0 then fail('empty argument range must start at zero',pc) end
                elseif not integer(first,1,proto.registers) or first+count-1>proto.registers then
                    fail('argument register range out of bounds',pc)
                end
            end
            if spec.writeRange then
                local first,size=ins[spec.writeRange.first],spec.writeRange.size
                if not integer(first,1,proto.registers) or size>proto.registers-first+1 then
                    fail('result register range out of bounds',pc)
                end
            end
            if spec.guardTuple and ins[3]~=5 then fail('tuple guard requires five values',pc) end
            if ins.op=='BIN' and not integer(ins[4],1,14) then fail('invalid binary operator',pc) end
            if ins.op=='UN' and not integer(ins[3],1,3) then fail('invalid unary operator',pc) end
            if ins.op=='JMPIF' and ins[3]~=0 and ins[3]~=1 then fail('invalid branch truth flag',pc) end
            if ins.op=='PICK' and ins[3]<1 then fail('pack index must be positive',pc) end
            if ins.op=='SETLIST' and ins[2]<1 then fail('array index must be positive',pc) end
            if ins.op=='VARARG' and not proto.vararg then fail('vararg read in a non-vararg function',pc) end
            if ins.op=='GETGLOBAL' or ins.op=='SETGLOBAL' then
                local position=ins.op=='GETGLOBAL' and 2 or 1
                if proto.constants[ins[position]].kind~='string' then fail('global name must be a string',pc) end
            end
            if proto.localsOptimized and (ins.op=='GETLOCAL1' or ins.op=='NEWLOCAL1'
                or ins.op=='SETLOCAL1' or ins.op=='LOADLOCAL') then
                local slot=ins[ins.op=='GETLOCAL1' and 2 or 1]
                if proto.boxed[slot] then fail('unboxed instruction accesses a captured local',pc) end
            end
            if proto.localsOptimized and (ins.op=='GETLOCAL' or ins.op=='NEWLOCAL'
                or ins.op=='SETLOCAL' or ins.op=='LOADLOCALC') then
                local slot=ins[ins.op=='GETLOCAL' and 2 or 1]
                if not proto.boxed[slot] then fail('boxed instruction accesses an unboxed local',pc) end
            end
        end
        for index,child in ipairs(proto.children) do check(child,proto,path..'.'..index) end
    end
    check(root,nil,'root')
    return true
end

return M
