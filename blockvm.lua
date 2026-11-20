-- Runtime sources for prototype keys and deferred instruction blocks.
local protection=require('src.protection')
local M={}

function M.render(config,quote,number)
    local v3=(config.version or 1)>=3
    local layout=config.layout or {op=0,a=1,b=5,c=9,d=13}
    local offsets={layout.a,layout.b,layout.c,layout.d}
    local masks=v3 or config.operandKeys or config.operandStrides
    local decode=[=[
local __ovm_instructionoffsets = {@OFFSETS@}
local function __ovm_decodeopcode(__ovm_p,__ovm_wireop)
    @OPMAP@
end
local function __ovm_decodeinstruction(__ovm_p,__ovm_data,__ovm_at,__ovm_pc)
    local __ovm_available=__ovm_buffer.len(__ovm_data)
    if __ovm_at<0 or __ovm_at+@OPWIDTH@>__ovm_available then __ovm_error('',0) end
    local __ovm_op=__ovm_decodeopcode(__ovm_p,__ovm_buffer.readu8(__ovm_data,__ovm_at+@OP@))
    local __ovm_fields=__ovm_buffer.readu8(__ovm_instrsizes,__ovm_op)
    if __ovm_fields==0 then __ovm_error('',0) end
    local __ovm_size=@SIZE@
    if __ovm_at+__ovm_size>__ovm_available then __ovm_error('',0) end
    local __ovm_a,__ovm_b,__ovm_c,__ovm_d=0,0,0,0
    local __ovm_order=__ovm_buffer.readu8(__ovm_instrorders,__ovm_op)
    for __ovm_field=0,@FIELDCOUNT@ do
        local __ovm_id=@FIELDID@
        local __ovm_value=@READ@
        @MASK@
        if __ovm_id==1 then __ovm_a=__ovm_value
        elseif __ovm_id==2 then __ovm_b=__ovm_value
        elseif __ovm_id==3 then __ovm_c=__ovm_value
        else __ovm_d=__ovm_value end
    end
    __ovm_validateinstruction(__ovm_p,__ovm_pc,__ovm_op,__ovm_a,__ovm_b,__ovm_c,__ovm_d)
    return __ovm_op,__ovm_a,__ovm_b,__ovm_c,__ovm_d,__ovm_at+__ovm_size
end
]=]
    local values={OFFSETS=table.concat(offsets,','),OP=tostring(config.compact and 0 or layout.op),
        OPWIDTH=tostring(config.compact and 1 or 17),
        OPMAP=config.perPrototypeOpcodes and "local __ovm_op=__ovm_p.opcodeMap[__ovm_wireop+1]\n    if __ovm_op==nil then __ovm_error('',0) end\n    return __ovm_op" or 'return __ovm_wireop',
        SIZE=config.compact and '1+(__ovm_fields-1)*__ovm_p.width' or '17',
        FIELDCOUNT=config.compact and '__ovm_fields-2' or '3',
        FIELDID=config.compact and '__ovm_bit.extract(__ovm_order,__ovm_field*2,2)+1' or '__ovm_field+1',
        READ=config.compact and '__ovm_p.read(__ovm_data,__ovm_at+1+__ovm_field*__ovm_p.width)' or '__ovm_buffer.readu32(__ovm_data,__ovm_at+__ovm_instructionoffsets[__ovm_id])',
        MASK=masks and ('__ovm_value=(__ovm_value-'..(v3 and '__ovm_p.operandKeys' or '__ovm_fieldkeys')..'[__ovm_id]-__ovm_pc*'..(v3 and '__ovm_p.operandStrides' or '__ovm_fieldstrides')..'[__ovm_id]-__ovm_p.id*5153)%'..(config.compact and '__ovm_p.modulus' or '4294967296')) or ''}
    decode=decode:gsub('@([A-Z]+)@',function(k) return assert(values[k]) end)
    local header=''
    if v3 then header=[=[
    local __ovm_headerstart=__ovm_offset
    __ovm_p.constantSeed=__ovm_u32()
    if __ovm_p.constantSeed<1 or __ovm_p.constantSeed>2147483646 then __ovm_error('',0) end
    __ovm_p.operandKeys,__ovm_p.operandStrides={},{}
    for __ovm_i=1,4 do __ovm_p.operandKeys[__ovm_i]=__ovm_u32() end
    for __ovm_i=1,4 do
        local __ovm_stride=__ovm_u32()
        if __ovm_stride<1 or __ovm_stride>2047 or __ovm_stride%2==0 then __ovm_error('',0) end
        __ovm_p.operandStrides[__ovm_i]=__ovm_stride
    end
    local __ovm_mapcount=__ovm_counted(2,__ovm_limits.mapEntries)
    @MAPCOUNT@
    __ovm_p.opcodeMap={}
    local __ovm_mapseen={}
    for __ovm_i=1,__ovm_mapcount do
        local __ovm_wireop,__ovm_op=__ovm_u8(),__ovm_u8()
        if __ovm_p.opcodeMap[__ovm_wireop+1]~=nil or __ovm_mapseen[__ovm_op] or __ovm_buffer.readu8(__ovm_instrsizes,__ovm_op)==0 then __ovm_error('',0) end
        __ovm_p.opcodeMap[__ovm_wireop+1]=__ovm_op
        __ovm_mapseen[__ovm_op]=true
    end
    local __ovm_headerhash1,__ovm_headerhash2=__ovm_blockdigest(__ovm_bytes,__ovm_headerstart,__ovm_offset-__ovm_headerstart,__ovm_p.constantSeed)
    __ovm_p.blockDomain=(__ovm_headerhash1+__ovm_headerhash2)%2147483646+1
]=]
        header=header:gsub('@MAPCOUNT@',config.perPrototypeOpcodes and "if __ovm_mapcount==0 then __ovm_error('',0) end" or "if __ovm_mapcount~=0 then __ovm_error('',0) end")
    end
    local codeLoad,blockHelper,frame,at='','','',''
    if config.lazyInstructions then
        codeLoad=[=[
    __ovm_p.width=__ovm_u8()
    if __ovm_p.width~=1 and __ovm_p.width~=2 and __ovm_p.width~=4 then __ovm_error('',0) end
    @FIXEDWIDTH@
    __ovm_p.read=__ovm_p.width==1 and __ovm_buffer.readu8 or __ovm_p.width==2 and __ovm_buffer.readu16 or __ovm_buffer.readu32
    __ovm_p.modulus=2^(__ovm_p.width*8)
    __ovm_p.blockSize=__ovm_u32()
    if __ovm_p.blockSize<1 or __ovm_p.blockSize>256 then __ovm_error('',0) end
    local __ovm_blockcount=__ovm_counted(12,__ovm_limits.instructions)
    if __ovm_blockcount~=__ovm_floor((__ovm_p.count+__ovm_p.blockSize-1)/__ovm_p.blockSize) then __ovm_error('',0) end
    __ovm_p.blocks={}
    for __ovm_i=1,__ovm_blockcount do
        local __ovm_size=__ovm_limit(__ovm_u32(),__ovm_limits.blockBytes)
        local __ovm_hash1,__ovm_hash2=__ovm_u32(),__ovm_u32()
        local __ovm_first=(__ovm_i-1)*__ovm_p.blockSize+1
        local __ovm_items=__ovm_p.count-__ovm_first+1
        if __ovm_items>__ovm_p.blockSize then __ovm_items=__ovm_p.blockSize end
        if __ovm_size<@MINBYTES@*__ovm_items or __ovm_size>@MAXBYTES@*__ovm_items then __ovm_error('',0) end
        __ovm_need(__ovm_size)
        __ovm_p.blocks[__ovm_i]={offset=__ovm_offset,size=__ovm_size,first=__ovm_first,count=__ovm_items,hash1=__ovm_hash1,hash2=__ovm_hash2}
        __ovm_offset=__ovm_offset+__ovm_size
    end
]=]
        codeLoad=codeLoad:gsub('@FIXEDWIDTH@',config.compact and '' or "if __ovm_p.width~=4 then __ovm_error('',0) end")
            :gsub('@MINBYTES@',config.compact and '1' or '17'):gsub('@MAXBYTES@',config.compact and '(1+4*__ovm_p.width)' or '17')
        blockHelper=[=[
local __ovm_instructioncaches={}
local function __ovm_materializeblock(__ovm_p,__ovm_blockindex,__ovm_blockcache)
    local __ovm_cached=__ovm_blockcache and __ovm_blockcache[__ovm_blockindex]
    if __ovm_cached then return __ovm_cached end
    local __ovm_descriptor=__ovm_p.blocks[__ovm_blockindex]
    if not __ovm_descriptor then __ovm_error('',0) end
    __ovm_limit(__ovm_descriptor.size,__ovm_limits.blockBytes)
    __ovm_limit(__ovm_descriptor.offset,__ovm_length)
    __ovm_limit(__ovm_descriptor.count,256)
    if __ovm_descriptor.count<1 or __ovm_descriptor.size>__ovm_length-__ovm_descriptor.offset then __ovm_error('',0) end
    local __ovm_key=__ovm_blockkey(__ovm_p.blockDomain,__ovm_p.id,__ovm_blockindex)
    local __ovm_state=__ovm_key
    local __ovm_data=__ovm_buffer.create(__ovm_descriptor.size)
    for __ovm_i=0,__ovm_descriptor.size-1 do
        __ovm_state=(__ovm_state*48271)%2147483647
        local __ovm_plain=(__ovm_buffer.readu8(__ovm_bytes,__ovm_descriptor.offset+__ovm_i)-__ovm_floor(__ovm_state/65536)%256)%256
        __ovm_buffer.writeu8(__ovm_data,__ovm_i,__ovm_plain)
        __ovm_state=(__ovm_state+__ovm_plain+__ovm_i%251)%2147483647
        if __ovm_state==0 then __ovm_state=1 end
    end
    local __ovm_hash1,__ovm_hash2=__ovm_blockdigest(__ovm_data,0,__ovm_descriptor.size,__ovm_key)
    if __ovm_hash1~=__ovm_descriptor.hash1 or __ovm_hash2~=__ovm_descriptor.hash2 then __ovm_error('',0) end
    local __ovm_entry={data=__ovm_data,sites={},checks={}}
    local __ovm_at=0
    for __ovm_index=1,__ovm_descriptor.count do
        local __ovm_pc=__ovm_descriptor.first+__ovm_index-1
        __ovm_entry.sites[__ovm_index]=__ovm_at
        local __ovm_op,__ovm_a,__ovm_b,__ovm_c,__ovm_d,__ovm_next=__ovm_decodeinstruction(__ovm_p,__ovm_data,__ovm_at,__ovm_pc)
        @CHECKS@
        __ovm_at=__ovm_next
    end
    if __ovm_at~=__ovm_descriptor.size then __ovm_error('',0) end
    @FREEZE@
    @OBSERVER@
    if __ovm_blockcache then __ovm_blockcache[__ovm_blockindex]=__ovm_entry end
    return __ovm_entry
end
]=]
        blockHelper=blockHelper:gsub('@CHECKS@',config.antiTamper and '__ovm_entry.checks[__ovm_index]={__ovm_op,__ovm_a,__ovm_b,__ovm_c,__ovm_d,__ovm_buffer.readstring(__ovm_data,__ovm_at,__ovm_next-__ovm_at)}' or '')
        blockHelper=blockHelper:gsub('@FREEZE@',config.antiTamper and 'for __ovm_i=1,#__ovm_entry.checks do __ovm_guardfreezeentry(__ovm_entry.checks[__ovm_i]) end\n    __ovm_guardfreezeentry(__ovm_entry.sites)\n    __ovm_guardfreezeentry(__ovm_entry.checks)\n    __ovm_guardfreezeentry(__ovm_entry)' or '')
        blockHelper=blockHelper:gsub('@OBSERVER@',config.debugBlocks and ('local __ovm_blockobserver=__ovm_entryenv.__verity_block\n    if __ovm_type(__ovm_blockobserver)=="function" then __ovm_blockobserver('..tostring(config.layer or 1)..',__ovm_p.id,__ovm_blockindex,__ovm_data) end') or '')
        local cache=config.instructionCache or 'prototype'
        assert(cache=='prototype' or cache=='execution' or cache=='none','invalid instruction cache')
        frame='local __ovm_blockcache='..(cache=='prototype' and '__ovm_instructioncaches[__ovm_p.id]' or cache=='execution' and '{}' or 'nil')..'\n'
        if cache=='prototype' then frame=frame..'if not __ovm_blockcache then __ovm_blockcache={} __ovm_instructioncaches[__ovm_p.id]=__ovm_blockcache end\n' end
        frame=frame..'local __ovm_activeblock,__ovm_blockentry,__ovm_instructionbytes,__ovm_checks\nlocal __ovm_checkindex=0\n'
        at=[=[
        local __ovm_blockindex=__ovm_floor((__ovm_pc-1)/__ovm_p.blockSize)+1
        if __ovm_activeblock~=__ovm_blockindex then
            __ovm_blockentry=__ovm_blockcache and __ovm_blockcache[__ovm_blockindex]
            if not __ovm_blockentry then __ovm_blockentry=__ovm_materializeblock(__ovm_p,__ovm_blockindex,__ovm_blockcache) end
            __ovm_instructionbytes=__ovm_blockentry.data
            __ovm_checks=__ovm_blockentry.checks
            __ovm_activeblock=__ovm_blockindex
        end
        __ovm_checkindex=__ovm_pc-(__ovm_blockindex-1)*__ovm_p.blockSize
        local __ovm_at=__ovm_blockentry.sites[__ovm_checkindex]
]=]
    end
    return {decode=decode,header=header,codeLoad=codeLoad,helpers=blockHelper,frame=frame,at=at,
        protection=(v3 or config.payloadDigest1) and protection.runtimeSource() or ''}
end
return M
