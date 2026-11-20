local M = {signature='VERITY_',wireVersion=3}
local codec=require('src.codec')
local cipher=require('src.cipher')
local instructions=require('src.instructions')
local protection=require('src.protection')
local util=require('src.util')
M.opnames = instructions.names

function M.opcodes(rng,used)
    local map, order, aliases = {}, {}, {}
    local clusters,total={},0
    for _,name in ipairs(M.opnames) do
      if not used or used[name] then
        local count,gap=rng:int(2,4),rng:int(0,3)
        clusters[#clusters+1]={name=name,count=count,gap=gap}
        total=total+count+gap
      end
    end
    -- New fused operations must still fit the byte opcode space for every seed.
    if total>255 then
        for _,cluster in ipairs(clusters) do
            local remove=math.min(cluster.gap,total-255)
            cluster.gap=cluster.gap-remove; total=total-remove
            if total<=255 then break end
        end
    end
    assert(total<=255,'too many opcode aliases')
    rng:shuffle(clusters)
    local offset=rng:int(1,256-total)
    for i,cluster in ipairs(clusters) do
        local name=cluster.name
        offset=offset+cluster.gap
        local ids={}
        for _=1,cluster.count do ids[#ids+1]=offset; offset=offset+1 end
        rng:shuffle(ids)
        map[name],aliases[name],order[i]=ids[1],ids,name
    end
    rng:shuffle(order)
    return map, order, aliases
end

function M.layout(rng)
    local fields=rng:shuffle({'op','a','b','c','d'})
    local layout,offset={},0
    for _,name in ipairs(fields) do
        layout[name]=offset
        offset=offset+(name=='op' and 1 or 4)
    end
    return layout,fields
end

function M.operandMasks(rng)
    local keys,strides={},{}
    for _,field in ipairs({'a','b','c','d'}) do
        keys[field]=rng:int(0,65535)*65536+rng:int(0,65535)
        strides[field]=rng:int(1,1023)*2+1
    end
    return keys,strides
end

function M.operatorIds(rng)
    local candidates,seen={},{}
    for i=1,17 do
        local value
        repeat value=rng:int(1,65535) until not seen[value]
        candidates[i],seen[value]=value,true
    end
    local binary,unary={},{}
    for i=1,14 do binary[i]=candidates[i] end
    for i=1,3 do unary[i]=candidates[14+i] end
    return binary,unary
end

local function numberText(n)
    if n ~= n then return 'nan' end
    if n == math.huge then return 'inf' end
    if n == -math.huge then return '-inf' end
    local text=string.format('%.17g', n)
    local separator=string.format('%.1f',0.5):match('^0(.-)5$')
    if separator and separator~='.' then
        local first,last=text:find(separator,1,true)
        if first then text=text:sub(1,first-1)..'.'..text:sub(last+1) end
    end
    return text
end
M.numberText=numberText

function M.constantKey(key,prototype,index,tag)
    return (key+prototype*8191+index*131+tag*17)%2147483646+1
end

function M.fieldOrder(name,fields)
    local allowed,result={},{}
    for _,field in ipairs(assert(instructions.specs[name]).fields) do allowed[field]=true end
    for _,field in ipairs(fields or {'op','a','b','c','d'}) do
        if allowed[field] then result[#result+1]=field end
    end
    return result
end

local function checksum(source)
    local hash=5381
    for i=1,#source do hash=(hash*33+source:byte(i))%4294967296 end
    return hash
end

function M.encode(root, opcodes, seed, options)
    options=options or {}
    local version=options.version or 1
    local flags=(options.compact and 1 or 0)+(options.lazyConstants and 2 or 0)+(options.debug and 4 or 0)
        +(options.perPrototypeOpcodes and 8 or 0)+(options.lazyInstructions and 16 or 0)
    assert(version==1 or version==2 or version==3,'invalid wire version')
    assert(version>=2 or flags==0,'wire v2 required for compact/lazy/debug')
    assert(version==3 or not options.perPrototypeOpcodes and not options.lazyInstructions,'wire v3 required for instruction protection')
    local blockSize=options.instructionBlockSize or options.blockSize or 32
    assert(type(blockSize)=='number' and blockSize>=1 and blockSize<=256 and blockSize%1==0,'blockSize must be an integer between 1 and 256')
    local rng=options.rng or (version==3 and util.rng(seed) or nil)
    local parts = {M.signature,string.char(version)}
    if version>=2 then parts[#parts+1]=string.char(flags) end
    local position=#M.signature+1+(version>=2 and 1 or 0)
    local function append(value) parts[#parts+1]=value; position=position+#value end
    local meta={version=version,flags=flags,compressed=false,constants=0,encryptedConstants=0,
        instructionBytes=0,legacyInstructionBytes=0,debugMap={prototypes={}},
        protection={blockCount=0,encryptedInstructionBytes=0,opcodeMaps=0,prototypes={}},
        limits={prototypes=0,params=0,slots=0,registers=0,upvalues=0,children=0,
            constants=0,instructions=0,constantBytes=0,blockBytes=0,mapEntries=0,
            tableEntries=0,arrayIndex=0,totalConstants=0,totalInstructions=0}}
    local function byte(n) append(string.char(n)) end
    local function packedSmall(n,width)
        assert(type(n)=='number' and n>=0 and n<=4294967295 and n==math.floor(n),'invalid integer operand')
        local bytes={}
        for i=1,width do bytes[i]=string.char(n%256); n=math.floor(n/256) end
        assert(n==0,'compact operand overflow'); return table.concat(bytes)
    end
    local function u32(n) append(packedSmall(n,4)) end
    local function small(n,width) append(packedSmall(n,width)) end
    local function str(s) u32(#s); append(s) end
    local list, ids = {}, {}
    local function visit(p)
        ids[p]=#list+1; list[#list+1]=p
        for _,child in ipairs(p.children) do visit(child) end
    end
    visit(root)
    if options.shufflePrototypes then
        rng:shuffle(list)
        for i,p in ipairs(list) do ids[p]=i end
    end
    meta.limits.prototypes=#list
    u32(#list)
    for prototypeId,p in ipairs(list) do
        local details={id=prototypeId,offsets={},blocks={}}
        meta.protection.prototypes[prototypeId]=details
        for _,field in ipairs({'params','upvalues','children','constants'}) do
            meta.limits[field]=math.max(meta.limits[field],#p[field])
        end
        meta.limits.slots=math.max(meta.limits.slots,p.slots)
        meta.limits.registers=math.max(meta.limits.registers,p.registers)
        meta.limits.instructions=math.max(meta.limits.instructions,#p.code)
        meta.limits.totalConstants=meta.limits.totalConstants+#p.constants
        meta.limits.totalInstructions=meta.limits.totalInstructions+#p.code
        local constantSeed=options.constantKey
        local prototypeKeys,prototypeStrides,opcodeMap,reverseMap
        if version==3 then
            local headerStart=#parts+1
            constantSeed=rng:int(1,2147483646)
            prototypeKeys,prototypeStrides=M.operandMasks(rng)
            details.key,details.keys,details.strides=constantSeed,prototypeKeys,prototypeStrides
            details.offsets.key=position; u32(constantSeed)
            details.offsets.keys={}; details.offsets.strides={}
            for index,field in ipairs({'a','b','c','d'}) do
                details.offsets.keys[index]=position; u32(prototypeKeys[field])
            end
            for index,field in ipairs({'a','b','c','d'}) do
                details.offsets.strides[index]=position; u32(prototypeStrides[field])
            end
            local canonical={}
            if options.perPrototypeOpcodes then
                local used={}; for _,ins in ipairs(p.code) do used[ins.op]=true end
                for _,name in ipairs(M.opnames) do
                    if used[name] then
                        for _,id in ipairs(options.aliases and options.aliases[name] or {assert(opcodes[name])}) do
                            canonical[#canonical+1]=id
                        end
                    end
                end
                local candidates={}; for id=0,255 do candidates[#candidates+1]=id end
                rng:shuffle(candidates)
                opcodeMap,reverseMap={},{}
                for index,id in ipairs(canonical) do
                    assert(reverseMap[id]==nil,'duplicate canonical prototype opcode')
                    opcodeMap[candidates[index]],reverseMap[id]=id,candidates[index]
                end
                meta.protection.opcodeMaps=meta.protection.opcodeMaps+1
            end
            details.mapCount=#canonical; details.opcodeMap,details.reverseMap=opcodeMap,reverseMap
            meta.limits.mapEntries=math.max(meta.limits.mapEntries,#canonical)
            details.offsets.mapCount=position; u32(#canonical)
            details.offsets.mapEntries=position
            for _,id in ipairs(canonical) do byte(reverseMap[id]); byte(id) end
            local headerFirst,headerSecond=protection.digest(table.concat(parts,'',headerStart,#parts),constantSeed)
            details.blockDomain=(headerFirst+headerSecond)%2147483646+1
        end
        details.offsets.paramsCount=position
        u32(#p.params)
        details.offsets.params=position
        for _,slot in ipairs(p.params) do u32(slot) end
        details.offsets.vararg=position; byte(p.vararg and 1 or 0)
        details.offsets.slots=position; u32(p.slots)
        details.offsets.registers=position; u32(p.registers)
        if version>=2 then
            local boxed={}
            for slot=1,p.slots do if not p.localsOptimized or (p.boxed and p.boxed[slot]) then boxed[#boxed+1]=slot end end
            details.offsets.boxedCount=position
            u32(#boxed); for _,slot in ipairs(boxed) do u32(slot) end
        end
        details.offsets.upvaluesCount=position
        u32(#p.upvalues)
        for _,up in ipairs(p.upvalues) do byte(up.kind=='local' and 1 or 2); u32(up.index) end
        details.offsets.childrenCount=position
        u32(#p.children)
        for _,child in ipairs(p.children) do u32(ids[child]) end
        details.offsets.constantsCount=position
        u32(#p.constants)
        for index,k in ipairs(p.constants) do
            meta.constants=meta.constants+1
            if k.kind=='nil' then byte(0)
            elseif k.kind=='boolean' then byte(k.value and 2 or 1)
            elseif version>=2 and k.kind=='number' and k.value==math.floor(k.value)
                and k.value>=-2147483648 and k.value<=2147483647
                and not (k.value==0 and 1/k.value==-math.huge) then
                local zigzag=k.value>=0 and k.value*2 or -k.value*2-1
                local width=zigzag<=255 and 1 or zigzag<=65535 and 2 or 4
                byte(5); byte(width)
                if options.lazyConstants then
                    zigzag=(zigzag+M.constantKey(assert(constantSeed),prototypeId,index,5))%2^(width*8)
                    meta.encryptedConstants=meta.encryptedConstants+1
                end
                small(zigzag,width)
            elseif k.kind=='number' or k.kind=='string' then
                local tag=k.kind=='number' and 3 or 4
                local text=k.kind=='number' and numberText(k.value) or k.value
                meta.limits.constantBytes=math.max(meta.limits.constantBytes,#text)
                byte(tag)
                if options.lazyConstants then
                    u32(#text); u32(checksum(text))
                    append(cipher.crypt(text,{key=M.constantKey(assert(constantSeed),prototypeId,index,tag),multiplier=48271}))
                    meta.encryptedConstants=meta.encryptedConstants+1
                else str(text) end
            else error('unknown constant kind: '..tostring(k.kind)) end
        end
        details.offsets.codeCount=position; u32(#p.code)
        if options.debug then
            str(p.chunkname or '<input>')
            for pc,ins in ipairs(p.code) do u32(ins.line or (p.lines and p.lines[pc]) or 0) end
            local mapped={id=prototypeId,source=p.chunkname or '<input>',lines={}}
            for pc,ins in ipairs(p.code) do mapped.lines[pc]=ins.line or (p.lines and p.lines[pc]) or 0 end
            meta.debugMap.prototypes[prototypeId]=mapped
        end
        local valuesList,maximum={},0
        for pc,ins in ipairs(p.code) do
            assert(opcodes[ins.op], 'unknown opcode: '..tostring(ins.op))
            local id=opcodes[ins.op]
            if options.aliases then
                local aliases=options.aliases[ins.op]
                id=aliases[rng:int(1,#aliases)]
            end
            if reverseMap then id=assert(reverseMap[id]) end
            local values={op=id,a=ins[1] or 0,b=ins[2] or 0,c=ins[3] or 0,d=ins[4] or 0}
            if ins.op=='NEWTABLE' then meta.limits.tableEntries=math.max(meta.limits.tableEntries,values.b) end
            if ins.op=='PICK' then meta.limits.arrayIndex=math.max(meta.limits.arrayIndex,values.c) end
            if ins.op=='SETLIST' then meta.limits.arrayIndex=math.max(meta.limits.arrayIndex,values.b) end
            if ins.op=='BIN' and options.binaryIds then values.d=assert(options.binaryIds[values.d]) end
            if ins.op=='UN' and options.unaryIds then values.c=assert(options.unaryIds[values.c]) end
            valuesList[pc]=values
            for _,field in ipairs(M.fieldOrder(ins.op,options.fields)) do maximum=math.max(maximum,values[field]) end
        end
        local width=maximum<=255 and 1 or maximum<=65535 and 2 or 4
        if options.compact or options.lazyInstructions then
            details.offsets.width=position; byte(options.compact and width or 4)
        end
        local encodedInstructions={}
        for pc,ins in ipairs(p.code) do
            local values=valuesList[pc]
            local order=options.compact and M.fieldOrder(ins.op,options.fields) or options.fields or {'op','a','b','c','d'}
            local instruction={}
            if options.compact then instruction[#instruction+1]=string.char(values.op) end
            for _,field in ipairs(order) do
                if field=='op' then instruction[#instruction+1]=string.char(values.op)
                else
                    local value=values[field]
                    local modulus=options.compact and 2^(width*8) or 4294967296
                    if version==3 then
                        value=(value+prototypeKeys[field]+pc*prototypeStrides[field]+prototypeId*5153)%modulus
                    elseif options.operandKeys and not options.maskOnLoad then
                        value=(value+options.operandKeys[field]+pc*options.operandStrides[field]+prototypeId*5153)%modulus
                    end
                    instruction[#instruction+1]=packedSmall(value,options.compact and width or 4)
                end
            end
            encodedInstructions[pc]=table.concat(instruction)
            meta.instructionBytes=meta.instructionBytes+(options.compact and (1+#order*width) or 17)
            meta.legacyInstructionBytes=meta.legacyInstructionBytes+17
        end
        if options.lazyInstructions then
            local blocks=math.ceil(#p.code/blockSize)
            details.offsets.blockSize=position; u32(blockSize)
            details.offsets.blockCount=position; u32(blocks)
            for block=1,blocks do
                local first=(block-1)*blockSize+1
                local last=math.min(block*blockSize,#p.code)
                local plain=table.concat(encodedInstructions,'',first,last)
                local key=protection.blockKey(details.blockDomain,prototypeId,block)
                local firstHash,secondHash=protection.digest(plain,key)
                local encrypted=cipher.crypt(plain,{key=key,multiplier=48271})
                local descriptor={headerOffset=position,size=#encrypted,first=first,count=last-first+1,
                    key=key,digest1=firstHash,digest2=secondHash}
                details.blocks[block]=descriptor
                u32(#encrypted); u32(firstHash); u32(secondHash)
                descriptor.offset=position; append(encrypted)
                meta.protection.blockCount=meta.protection.blockCount+1
                meta.protection.encryptedInstructionBytes=meta.protection.encryptedInstructionBytes+#encrypted
                meta.limits.blockBytes=math.max(meta.limits.blockBytes,#encrypted)
            end
        else
            details.instructionOffset=position
            append(table.concat(encodedInstructions))
        end
    end
    local plain = table.concat(parts)
    meta.limits.payloadBytes=#plain
    meta.payloadDigestKey=options.constantKey or seed
    meta.payloadDigest1,meta.payloadDigest2=protection.digest(plain,meta.payloadDigestKey)
    local packed=options.compression and codec.compress(plain) or plain
    if options.adaptiveCompression and #packed>=#plain then packed=plain end
    meta.compressed=options.compression and packed~=plain or false
    meta.debugMap.entry=ids[root]
    local encrypted, checksum = {}, 5381
    for i=1,#plain do
        local b = string.byte(plain,i)
        checksum = (checksum*33+b)%4294967296
    end
    if options.cipher then
        return cipher.crypt(packed,options.cipher),checksum,#plain,#packed,ids[root],meta
    end
    for i=1,#packed do
        local b=string.byte(packed,i)
        local offset = i-1
        encrypted[i] = string.char((b+(seed+offset*73+math.floor(offset/256)*19)%256)%256)
    end
    return table.concat(encrypted), checksum, #plain, #packed,ids[root],meta
end

return M
