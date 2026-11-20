-- Runtime validation generated from the same operand contract as the compiler.
-- Counts are bounded before loops; decoded instructions are checked before use.
local instructions=require('src.instructions')
local M={}

M.defaults={payloadBytes=67108864,prototypes=65536,params=65536,slots=1048576,
    registers=1048576,upvalues=65536,children=65536,constants=1048576,
    instructions=4194304,constantBytes=16777216,blockBytes=1048576,mapEntries=256,
    tableEntries=1048576,arrayIndex=4294967295,totalConstants=1048576,totalInstructions=4194304}
local limitNames={'payloadBytes','prototypes','params','slots','registers','upvalues',
    'children','constants','instructions','constantBytes','blockBytes','mapEntries',
    'tableEntries','arrayIndex','totalConstants','totalInstructions'}

function M.normalize(limits)
    if limits==nil then limits={} end
    assert(type(limits)=='table','loader limits must be a table')
    local result={}
    for _,name in ipairs(limitNames) do
        local value=limits[name]
        if value==nil then value=M.defaults[name] end
        assert(type(value)=='number' and value>=0 and value<=4294967295
            and value==math.floor(value),'invalid loader limit '..name)
        result[name]=value
    end
    return result
end

local helperSource=[=[
local function __ovm_limit(__ovm_value, __ovm_cap)
    if __ovm_type(__ovm_value) ~= 'number' or __ovm_value < 0 or __ovm_value > __ovm_cap
        or __ovm_value ~= __ovm_floor(__ovm_value) then __ovm_error('', 0) end
    return __ovm_value
end
local function __ovm_counted(__ovm_minimum, __ovm_cap)
    local __ovm_value = __ovm_limit(__ovm_u32(), __ovm_cap)
    if __ovm_value * __ovm_minimum > __ovm_length - __ovm_offset then __ovm_error('', 0) end
    return __ovm_value
end
]=]

local postloadSource=[=[
do
    local __ovm_parents = {}
    for __ovm_id = 1, __ovm_count do
        local __ovm_p = __ovm_protos[__ovm_id]
        if not __ovm_p or __ovm_p.id ~= __ovm_id then __ovm_error('', 0) end
        local __ovm_parameters = {}
        for __ovm_i = 1, #__ovm_p.params do
            local __ovm_slot = __ovm_p.params[__ovm_i]
            if __ovm_slot < 1 or __ovm_slot > __ovm_p.slots or __ovm_parameters[__ovm_slot] then __ovm_error('', 0) end
            __ovm_parameters[__ovm_slot] = true
        end
        for __ovm_i = 1, #__ovm_p.children do
            local __ovm_child = __ovm_p.children[__ovm_i]
            if __ovm_child < 1 or __ovm_child > __ovm_count or __ovm_child == __ovm_entry.id
                or __ovm_parents[__ovm_child] then __ovm_error('', 0) end
            __ovm_parents[__ovm_child] = __ovm_id
        end
    end
    if #__ovm_entry.upvalues ~= 0 or __ovm_parents[__ovm_entry.id] then __ovm_error('', 0) end
    for __ovm_id = 1, __ovm_count do
        local __ovm_p = __ovm_protos[__ovm_id]
        if __ovm_p ~= __ovm_entry then
            local __ovm_parent = __ovm_protos[__ovm_parents[__ovm_id]]
            if not __ovm_parent then __ovm_error('', 0) end
            for __ovm_i = 1, #__ovm_p.upvalues do
                local __ovm_up = __ovm_p.upvalues[__ovm_i]
                if __ovm_up.kind == 1 then
                    if __ovm_up.index < 1 or __ovm_up.index > __ovm_parent.slots
                        or (__ovm_parent.boxed and not __ovm_parent.boxed[__ovm_up.index]) then __ovm_error('', 0) end
                elseif __ovm_up.kind == 2 then
                    if __ovm_up.index < 1 or __ovm_up.index > #__ovm_parent.upvalues then __ovm_error('', 0) end
                else __ovm_error('', 0) end
            end
        end
    end
    -- A parent count alone permits a disconnected cycle. Traverse from the
    -- actual entry with a bounded queue to require that every prototype is used.
    local __ovm_queue, __ovm_seen = {__ovm_entry.id}, {}
    local __ovm_head, __ovm_tail = 1, 1
    while __ovm_head <= __ovm_tail do
        local __ovm_id = __ovm_queue[__ovm_head]
        if __ovm_seen[__ovm_id] or __ovm_head > __ovm_count then __ovm_error('', 0) end
        __ovm_seen[__ovm_id] = true
        local __ovm_p = __ovm_protos[__ovm_id]
        for __ovm_i = 1, #__ovm_p.children do
            __ovm_tail = __ovm_tail + 1
            if __ovm_tail > __ovm_count then __ovm_error('', 0) end
            __ovm_queue[__ovm_tail] = __ovm_p.children[__ovm_i]
        end
        __ovm_head = __ovm_head + 1
    end
    if __ovm_tail ~= __ovm_count then __ovm_error('', 0) end
end
]=]

function M.render(config,quote,number)
    assert(type(config)=='table' and type(config.opcodes)=='table','loader config requires opcodes')
    quote=quote or function(value) return string.format('%q',value) end
    number=number or tostring
    local limits=M.normalize(config.limits)
    local encoded={}
    for _,name in ipairs(limitNames) do encoded[#encoded+1]=name..'='..number(limits[name]) end
    local limitSource='local __ovm_limits = {'..table.concat(encoded,',')..'}\n'
    local schema,branches={},{}
    for index=1,256 do schema[index]=string.char(0) end
    local args={'__ovm_a','__ovm_b','__ovm_c','__ovm_d'}
    local version=config.version or 1
    for ordinal,name in ipairs(instructions.names) do
        if config.opcodes[name]~=nil then
            local aliases=config.aliases and config.aliases[name] or {config.opcodes[name]}
            assert(type(aliases)=='table' and #aliases>0,'missing loader aliases '..name)
            for _,alias in ipairs(aliases) do
                assert(type(alias)=='number' and alias>=0 and alias<=255 and alias==math.floor(alias),'invalid loader alias')
                assert(schema[alias+1]==string.char(0),'duplicate loader alias')
                schema[alias+1]=string.char(ordinal)
            end
            local spec=instructions.specs[name]
            local tests,used={},{}
            for _,field in ipairs(spec.fields) do used[instructions.positions[field]]=true end
            for position=1,4 do if not used[position] then tests[#tests+1]=args[position]..' ~= 0' end end
            local function indices(positions,limit)
                local seen={}
                for _,position in ipairs(positions) do
                    if not seen[position] then
                        seen[position]=true
                        tests[#tests+1]=args[position]..' < 1'
                        tests[#tests+1]=args[position]..' > '..limit
                    end
                end
            end
            local registers={}
            for _,position in ipairs(spec.reads) do registers[#registers+1]=position end
            for _,position in ipairs(spec.writes) do registers[#registers+1]=position end
            indices(registers,'__ovm_p.registers')
            local slots={}
            for _,position in ipairs(spec.slotReads) do slots[#slots+1]=position end
            for _,position in ipairs(spec.slotWrites) do slots[#slots+1]=position end
            indices(slots,'__ovm_p.slots')
            indices(spec.constant,'(__ovm_p.constantCount or #__ovm_p.constants)')
            indices(spec.child,'#__ovm_p.children')
            indices(spec.upvalue,'#__ovm_p.upvalues')
            if spec.branch then indices({spec.branch},'__ovm_p.count') end
            if not spec.terminal and not spec.unconditional then tests[#tests+1]='__ovm_pc == __ovm_p.count' end
            if spec.range then
                local first,count=args[spec.range.first],args[spec.range.count]
                tests[#tests+1]='('..count..' == 0 and '..first..' ~= 0)'
                tests[#tests+1]='('..count..' > 0 and ('..first..' < 1 or '..count..' > __ovm_p.registers - '..first..' + 1))'
            end
            if spec.writeRange then
                local first=args[spec.writeRange.first]
                tests[#tests+1]='('..first..' < 1 or '..number(spec.writeRange.size)..' > __ovm_p.registers - '..first..' + 1)'
            end
            if spec.guardTuple then tests[#tests+1]='__ovm_c ~= 5' end
            if name=='BIN' or name=='UN' then
                local ids=name=='BIN' and config.binaryIds or config.unaryIds
                local count=name=='BIN' and 14 or 3
                local operand=name=='BIN' and args[4] or args[3]
                local allowed={}
                for id=1,count do allowed[#allowed+1]=operand..' ~= '..number(ids and assert(ids[id]) or id) end
                tests[#tests+1]='('..table.concat(allowed,' and ')..')'
            end
            if name=='JMPIF' then tests[#tests+1]='(__ovm_c ~= 0 and __ovm_c ~= 1)' end
            if name=='NEWTABLE' then tests[#tests+1]='__ovm_b > __ovm_limits.tableEntries' end
            if name=='PICK' then
                tests[#tests+1]='__ovm_c < 1'
                tests[#tests+1]='__ovm_c > __ovm_limits.arrayIndex'
            end
            if name=='SETLIST' then
                tests[#tests+1]='__ovm_b < 1'
                tests[#tests+1]='__ovm_b > __ovm_limits.arrayIndex'
            end
            if name=='VARARG' then tests[#tests+1]='not __ovm_p.vararg' end
            local statements={}
            if #tests>0 then statements[#statements+1]="if "..table.concat(tests,' or ').." then __ovm_error('', 0) end" end
            if name=='GETGLOBAL' or name=='SETGLOBAL' then
                local at=name=='GETGLOBAL' and args[2] or args[1]
                local invalid=version>=2 and ('__ovm_p.constants['..at..'].tag ~= 4')
                    or ("__ovm_type(__ovm_p.constants["..at.."]) ~= 'string'")
                statements[#statements+1]="if "..invalid.." then __ovm_error('', 0) end"
            end
            if version>=2 then
                local boxed=name=='GETLOCAL' or name=='NEWLOCAL' or name=='SETLOCAL' or name=='LOADLOCALC'
                local unboxed=name=='GETLOCAL1' or name=='NEWLOCAL1' or name=='SETLOCAL1' or name=='LOADLOCAL'
                if boxed or unboxed then
                    local slot=(name=='GETLOCAL' or name=='GETLOCAL1') and args[2] or args[1]
                    local value='__ovm_p.boxed['..slot..']'
                    statements[#statements+1]="if "..(boxed and 'not '..value or value).." then __ovm_error('', 0) end"
                end
            end
            branches[#branches+1]=( #branches==0 and 'if ' or 'elseif ' )..'__ovm_schema == '..number(ordinal)..' then\n'
                ..table.concat(statements,'\n')
        end
    end
    assert(#branches>0,'loader requires at least one opcode')
    local validate='local __ovm_loaderschema = __ovm_buffer.fromstring('..quote(table.concat(schema))..')\n'
        ..[=[
local function __ovm_validateinstruction(__ovm_p, __ovm_pc, __ovm_op, __ovm_a, __ovm_b, __ovm_c, __ovm_d)
    __ovm_limit(__ovm_pc, __ovm_p.count)
    __ovm_limit(__ovm_op, 255)
    __ovm_limit(__ovm_a, 4294967295)
    __ovm_limit(__ovm_b, 4294967295)
    __ovm_limit(__ovm_c, 4294967295)
    __ovm_limit(__ovm_d, 4294967295)
    if __ovm_pc < 1 then __ovm_error('', 0) end
    local __ovm_schema = __ovm_buffer.readu8(__ovm_loaderschema, __ovm_op)
]=]..table.concat(branches,'\n').."\nelse __ovm_error('', 0) end\n    return true\nend\n"
    return {limits=limitSource,helpers=helperSource,postload=postloadSource,validate=validate,settings=limits}
end

return M
