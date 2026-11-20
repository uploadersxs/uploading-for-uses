local M = {}

local function copy(ins)
    return {op = ins.op, line=ins.line, ins[1] or 0, ins[2] or 0, ins[3] or 0, ins[4] or 0}
end

local function targetOperand(ins)
    if ins.op == 'JMP' then return 1 end
    if ins.op == 'JMPIF' or ins.op == 'OPAQUE' then return 2 end
end

local function returns(op)
    return op=='RETURN' or op=='RETURN0' or op=='RETURN1'
end

local function noise(code, rng, options, stats)
    local output, addresses, branches = {}, {}, {}
    for pc, ins in ipairs(code) do
        addresses[pc] = #output + 1
        if rng:chance(options.junk) then
            output[#output + 1] = {op='NOP',line=ins.line, rng:int(1,32767), rng:int(1,32767), rng:int(1,32767), rng:int(1,32767)}
            stats.junk = stats.junk + 1
        end
        if options.opaque and (pc == 1 or rng:chance(options.junk)) then
            local gate = {op='OPAQUE',line=ins.line, 0, #output + 3, rng:int(1,32767), rng:int(1,32767)}
            output[#output + 1] = gate
            output[#output + 1] = {op='NOP',line=ins.line, rng:int(1,32767), rng:int(1,32767), rng:int(1,32767), rng:int(1,32767)}
            stats.opaque = stats.opaque + 1
            stats.junk = stats.junk + 1
        end
        local cloned = copy(ins)
        output[#output + 1] = cloned
        local operand = targetOperand(cloned)
        if operand then branches[#branches + 1] = {cloned, operand} end
    end
    addresses[#code + 1] = #output + 1
    for _, branch in ipairs(branches) do
        local oldTarget = branch[1][branch[2]]
        assert(addresses[oldTarget], 'invalid compiler branch target: ' .. tostring(oldTarget))
        branch[1][branch[2]] = addresses[oldTarget]
    end
    return output
end

local function flatten(code, rng, stats)
    local starts = {[1]=true}
    for pc, ins in ipairs(code) do
        local operand = targetOperand(ins)
        if operand then
            assert(ins[operand] >= 1 and ins[operand] <= #code, 'branch outside prototype')
            starts[ins[operand]] = true
        end
        if operand or returns(ins.op) then
            if pc < #code then starts[pc + 1] = true end
        end
    end
    local positions = {}
    for pc in pairs(starts) do positions[#positions + 1] = pc end
    table.sort(positions)
    local blocks = {}
    for i, first in ipairs(positions) do
        local last = (positions[i + 1] or (#code + 1)) - 1
        local block = {start=first, code={}}
        for pc=first,last do block.code[#block.code + 1] = {old=pc, ins=copy(code[pc])} end
        local terminal = code[last].op
        if terminal ~= 'JMP' and not returns(terminal) and terminal ~= 'OPAQUE' and last < #code then
            block.code[#block.code + 1] = {ins={op='JMP',line=code[last].line, last + 1, 0,0,0}}
        end
        blocks[#blocks + 1] = block
    end
    rng:shuffle(blocks)
    local output = {{op='JMP',line=code[1].line, 0,0,0,0}}
    local remap = {}
    for _, block in ipairs(blocks) do
        for _, record in ipairs(block.code) do
            if record.old then remap[record.old] = #output + 1 end
            output[#output + 1] = record.ins
        end
    end
    for pc=2,#output do
        local ins = output[pc]
        local operand = targetOperand(ins)
        if operand then
            assert(remap[ins[operand]], 'invalid flattened jump')
            ins[operand] = remap[ins[operand]]
        end
    end
    output[1][1] = remap[1]
    stats.blocks = stats.blocks + #blocks
    return output
end

function M.apply(proto, rng, options, stats)
    stats = stats or {junk=0, opaque=0, blocks=0, instructions=0, originalInstructions=0, prototypes=0}
    stats.prototypes = stats.prototypes + 1
    stats.originalInstructions = stats.originalInstructions + #proto.code
    proto.code = noise(proto.code, rng, options, stats)
    if options.cff then proto.code = flatten(proto.code, rng, stats) end
    stats.instructions = stats.instructions + #proto.code
    for _, child in ipairs(proto.children) do M.apply(child, rng, options, stats) end
    return stats
end

return M
