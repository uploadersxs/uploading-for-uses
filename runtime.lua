-- Standalone Luau runtime generator. The generator itself runs on Lua 5.1+.
local runtime = {}
local base91 = require('src.base91')
local instructions = require('src.instructions')
local serialize = require('src.serialize')
local guards = require('src.guards')
local nativeHelpers = require('src.native')
local scheduler = require('src.scheduler')
local nativeHot = require('src.native_hot')
local fetch = require('src.fetch')
local closure = require('src.closure')
local loader = require('src.loader')
local blockvm = require('src.blockvm')

local function quoteBytes(value)
    local single, double = 0, 0
    for i = 1, #value do
        local byte = string.byte(value, i)
        if byte == 39 then single = single + 1 elseif byte == 34 then double = double + 1 end
    end
    local delimiter = single < double and "'" or '"'
    local named = {[7]='\\a',[8]='\\b',[9]='\\t',[10]='\\n',[11]='\\v',[12]='\\f',[13]='\\r'}
    local out = {delimiter}
    for i = 1, #value do
        local byte = string.byte(value, i)
        if byte == 92 then out[#out + 1] = '\\\\'
        elseif byte == string.byte(delimiter) then out[#out + 1] = '\\' .. delimiter
        elseif byte >= 32 and byte <= 126 then out[#out + 1] = string.char(byte)
        elseif named[byte] then out[#out + 1] = named[byte]
        else
            local nextByte = string.byte(value, i + 1)
            -- Decimal escapes consume up to three digits, including a following
            -- raw digit. Pad only in that case; all output remains ASCII.
            out[#out + 1] = '\\' .. ((nextByte and nextByte >= 48 and nextByte <= 57) and string.format('%03d', byte) or tostring(byte))
        end
    end
    out[#out + 1] = delimiter
    return table.concat(out)
end

local handlers = {
    LOADK = '__ovm_r[__ovm_a] = __ovm_constant(__ovm_p, __ovm_b, __ovm_cache)',
    MOVE = '__ovm_r[__ovm_a] = __ovm_r[__ovm_b]',
    GETLOCAL = '__ovm_r[__ovm_a] = __ovm_l[__ovm_b][1]',
    NEWLOCAL = '__ovm_l[__ovm_a] = {__ovm_r[__ovm_b]}',
    SETLOCAL = '__ovm_l[__ovm_a][1] = __ovm_r[__ovm_b]',
    GETLOCAL1 = '__ovm_r[__ovm_a] = __ovm_l[__ovm_b]',
    NEWLOCAL1 = '__ovm_l[__ovm_a] = __ovm_r[__ovm_b]',
    SETLOCAL1 = '__ovm_l[__ovm_a] = __ovm_r[__ovm_b]',
    LOADLOCAL = '__ovm_l[__ovm_a] = __ovm_constant(__ovm_p, __ovm_b, __ovm_cache)',
    LOADLOCALC = '__ovm_l[__ovm_a] = {__ovm_constant(__ovm_p, __ovm_b, __ovm_cache)}',
    GETUP = '__ovm_r[__ovm_a] = __ovm_u[__ovm_b][1]',
    SETUP = '__ovm_u[__ovm_a][1] = __ovm_r[__ovm_b]',
    GETGLOBAL = '__ovm_r[__ovm_a] = __ovm_env[__ovm_constant(__ovm_p, __ovm_b, __ovm_cache)]',
    SETGLOBAL = '__ovm_env[__ovm_constant(__ovm_p, __ovm_a, __ovm_cache)] = __ovm_r[__ovm_b]',
    GETTABLE = '__ovm_r[__ovm_a] = __ovm_r[__ovm_b][__ovm_r[__ovm_c]]',
    GETMETHOD = [=[
local __ovm_object = __ovm_r[__ovm_b]
local __ovm_meta = __ovm_type(__ovm_object) == 'userdata' and __ovm_getmetatable(__ovm_object)
if __ovm_type(__ovm_meta) == 'table' and __ovm_rawget(__ovm_meta, '__namecall') ~= nil then
    __ovm_r[__ovm_a] = function(...)
        return __ovm_rawget(__ovm_meta, '__namecall')(...)
    end
else __ovm_r[__ovm_a] = __ovm_object[__ovm_r[__ovm_c]] end]=],
    SETTABLE = '__ovm_r[__ovm_a][__ovm_r[__ovm_b]] = __ovm_r[__ovm_c]',
    NEWTABLE = '__ovm_r[__ovm_a] = __ovm_create(__ovm_b)',
    BIN = [=[
local __ovm_x, __ovm_y = __ovm_r[__ovm_b], __ovm_r[__ovm_c]
if __ovm_d == 1 then __ovm_r[__ovm_a] = __ovm_x + __ovm_y
elseif __ovm_d == 2 then __ovm_r[__ovm_a] = __ovm_x - __ovm_y
elseif __ovm_d == 3 then __ovm_r[__ovm_a] = __ovm_x * __ovm_y
elseif __ovm_d == 4 then __ovm_r[__ovm_a] = __ovm_x / __ovm_y
elseif __ovm_d == 5 then __ovm_r[__ovm_a] = __ovm_x // __ovm_y
elseif __ovm_d == 6 then __ovm_r[__ovm_a] = __ovm_x % __ovm_y
elseif __ovm_d == 7 then __ovm_r[__ovm_a] = __ovm_x ^ __ovm_y
elseif __ovm_d == 8 then __ovm_r[__ovm_a] = __ovm_x .. __ovm_y
elseif __ovm_d == 9 then __ovm_r[__ovm_a] = __ovm_x == __ovm_y
elseif __ovm_d == 10 then __ovm_r[__ovm_a] = __ovm_x ~= __ovm_y
elseif __ovm_d == 11 then __ovm_r[__ovm_a] = __ovm_x < __ovm_y
elseif __ovm_d == 12 then __ovm_r[__ovm_a] = __ovm_x <= __ovm_y
elseif __ovm_d == 13 then __ovm_r[__ovm_a] = __ovm_x > __ovm_y
elseif __ovm_d == 14 then __ovm_r[__ovm_a] = __ovm_x >= __ovm_y
else __ovm_error('', 0) end]=],
    UN = [=[
if __ovm_c == 1 then __ovm_r[__ovm_a] = -__ovm_r[__ovm_b]
elseif __ovm_c == 2 then __ovm_r[__ovm_a] = not __ovm_r[__ovm_b]
elseif __ovm_c == 3 then __ovm_r[__ovm_a] = #__ovm_r[__ovm_b]
else __ovm_error('', 0) end]=],
    JMP = '__ovm_pc = __ovm_a',
    JMPIF = 'if (not not __ovm_r[__ovm_a]) == (__ovm_c == 1) then __ovm_pc = __ovm_b end',
    PACK = '__ovm_r[__ovm_a] = {n=0}',
    PUSH = [=[
local __ovm_pack = __ovm_r[__ovm_a]
__ovm_pack.n = __ovm_pack.n + 1
__ovm_pack[__ovm_pack.n] = __ovm_r[__ovm_b]]=],
    EXTEND = [=[
local __ovm_to, __ovm_from = __ovm_r[__ovm_a], __ovm_r[__ovm_b]
local __ovm_base = __ovm_to.n
for __ovm_i = 1, __ovm_from.n do __ovm_to[__ovm_base + __ovm_i] = __ovm_from[__ovm_i] end
__ovm_to.n = __ovm_base + __ovm_from.n]=],
    PICK = '__ovm_r[__ovm_a] = __ovm_r[__ovm_b][__ovm_c]',
    CALL = [=[
local __ovm_args = __ovm_r[__ovm_c]
__ovm_r[__ovm_a] = __ovm_pack(__ovm_r[__ovm_b](__ovm_unpack(__ovm_args, 1, __ovm_args.n)))]=],
    CALL1 = [=[
local __ovm_args = __ovm_r[__ovm_c]
__ovm_r[__ovm_a] = __ovm_r[__ovm_b](__ovm_unpack(__ovm_args, 1, __ovm_args.n))]=],
    CALL0 = [=[
local __ovm_args = __ovm_r[__ovm_b]
__ovm_r[__ovm_a](__ovm_unpack(__ovm_args, 1, __ovm_args.n))]=],
    CALLF0 = '__ovm_r[__ovm_a](__ovm_unpack(__ovm_r, __ovm_b, __ovm_b + __ovm_c - 1))',
    CALLF1 = '__ovm_r[__ovm_a] = __ovm_r[__ovm_b](__ovm_unpack(__ovm_r, __ovm_c, __ovm_c + __ovm_d - 1))',
    CALLFN = '__ovm_r[__ovm_a] = __ovm_pack(__ovm_r[__ovm_b](__ovm_unpack(__ovm_r, __ovm_c, __ovm_c + __ovm_d - 1)))',
    GUARDTUPLE = [=[
local __ovm_expected=__ovm_r[__ovm_a]
if __ovm_r[__ovm_b]~=__ovm_expected[1]
    or __ovm_r[__ovm_b+1]~=__ovm_expected[2]
    or __ovm_r[__ovm_b+2]~=__ovm_expected[3]
    or __ovm_r[__ovm_b+3]~=__ovm_expected[4]
    or __ovm_r[__ovm_b+4]~=__ovm_expected[5] then __ovm_error('',0) end]=],
    RETURN = [=[
local __ovm_values = __ovm_r[__ovm_a]
return __ovm_unpack(__ovm_values, 1, __ovm_values.n)]=],
    RETURN1 = 'return __ovm_r[__ovm_a]',
    RETURN0 = 'return',
    VARARG = '__ovm_r[__ovm_a] = __ovm_v',
    TOSTRING = "__ovm_r[__ovm_a] = __ovm_format('%*', __ovm_r[__ovm_b])",
    CLOSURE = [=[
local __ovm_child = __ovm_protos[__ovm_p.children[__ovm_b]]
local __ovm_capture = {}
for __ovm_i, __ovm_uv in __ovm_ipairs(__ovm_child.upvalues) do
    if __ovm_uv.kind == 1 then __ovm_capture[__ovm_i] = __ovm_l[__ovm_uv.index]
    else __ovm_capture[__ovm_i] = __ovm_u[__ovm_uv.index] end
end
local __ovm_closure
__ovm_closure = function(...)
    return __ovm_run(__ovm_child, __ovm_capture, __ovm_pack(...), __ovm_getfenv(__ovm_closure))
end
__ovm_setfenv(__ovm_closure, __ovm_env)
__ovm_r[__ovm_a] = __ovm_closure]=],
    SETLIST = [=[
local __ovm_values, __ovm_table = __ovm_r[__ovm_c], __ovm_r[__ovm_a]
__ovm_move(__ovm_values, 1, __ovm_values.n, __ovm_b, __ovm_table)]=],
    NOP = '__ovm_junk = __ovm_bxor((__ovm_junk + __ovm_a + __ovm_b) % 4294967296, __ovm_c, __ovm_d)',
    OPAQUE = [=[
local __ovm_x, __ovm_y = __ovm_c, __ovm_d
if (__ovm_x + __ovm_y) * (__ovm_x + __ovm_y) == __ovm_x * __ovm_x + 2 * __ovm_x * __ovm_y + __ovm_y * __ovm_y then
    __ovm_pc = __ovm_b
else __ovm_error('', 0) end]=],
    ITERPREP = [=[
local __ovm_values = __ovm_r[__ovm_b]
local __ovm_object = __ovm_values[1]
local __ovm_kind = __ovm_type(__ovm_object)
if __ovm_kind == 'table' or __ovm_kind == 'userdata' then
    local __ovm_meta = __ovm_getmetatable(__ovm_object)
    if __ovm_meta ~= nil and __ovm_type(__ovm_meta) ~= 'table' then
        __ovm_error('', 0)
    end
    local __ovm_iter = __ovm_meta and __ovm_rawget(__ovm_meta, '__iter')
    local __ovm_call = __ovm_meta and __ovm_rawget(__ovm_meta, '__call')
    if __ovm_iter ~= nil then
        -- __iter is a native metamethod boundary and may not yield. A native
        -- callback retains that boundary while letting errors propagate.
        __ovm_gsub('x', 'x', function()
            __ovm_r[__ovm_a] = __ovm_pack(__ovm_iter(__ovm_object))
            return ''
        end)
    elseif __ovm_call ~= nil then
        __ovm_r[__ovm_a] = __ovm_values
    elseif __ovm_kind == 'table' then
        __ovm_r[__ovm_a] = __ovm_pack(__ovm_next, __ovm_object, nil)
    else __ovm_r[__ovm_a] = __ovm_values end
else __ovm_r[__ovm_a] = __ovm_values end]=],
    FORPREP = [=[
local __ovm_indices = {__ovm_a, __ovm_b, __ovm_c}
for __ovm_i = 1, 3 do
    local __ovm_index = __ovm_indices[__ovm_i]
    local __ovm_value = __ovm_r[__ovm_index]
    local __ovm_kind = __ovm_type(__ovm_value)
    local __ovm_number
    if __ovm_kind == 'number' or __ovm_kind == 'string' then __ovm_number = __ovm_tonumber(__ovm_value) end
    if __ovm_number == nil then __ovm_error('', 0) end
    __ovm_r[__ovm_index] = __ovm_number
end]=],
}

for results=2,6 do
    local destinations={}
    for index=0,results-1 do destinations[#destinations+1]='__ovm_r[__ovm_a+'..index..']' end
    handlers['CALLF'..results]=table.concat(destinations,',')
        ..'=__ovm_r[__ovm_b](__ovm_unpack(__ovm_r,__ovm_c,__ovm_c+__ovm_d-1))'
end

local template = [=[
return (function(__ovm_entryenv, ...)
local __ovm_buffer, __ovm_bit = buffer, bit32
local __ovm_error, __ovm_type, __ovm_tonumber = error, type, tonumber
local __ovm_floor, __ovm_pack, __ovm_unpack = math.floor, table.pack, table.unpack
local __ovm_create, __ovm_move = table.create, table.move
local __ovm_gsub, __ovm_format = string.gsub, string.format
local __ovm_ipairs, __ovm_next, __ovm_getmetatable, __ovm_rawget = ipairs, next, getmetatable, rawget
local __ovm_getfenv, __ovm_setfenv = getfenv, setfenv
@DEBUGLIB@
if not __ovm_buffer or not __ovm_bit then __ovm_error('', 0) end
local __ovm_bxor = __ovm_bit.bxor
@HOOKSETUP@
@GUARDSTARTUP@
@SCHEDULERSETUP@
@LOADERLIMITS@
@PROTECTIONHELPERS@
@TRANSPORTBOUND@
@TRANSPORT@
local __ovm_length = __ovm_buffer.len(__ovm_encrypted)
if __ovm_length > __ovm_limits.payloadBytes then __ovm_error('',0) end
local __ovm_bytes = __ovm_encrypted
@CIPHER@
__ovm_encrypted = nil
@DECOMPRESS@
@PAYLOADCHECKSUM@
@PAYLOADDIGEST@
local __ovm_offset = 0
local function __ovm_need(__ovm_size)
    if __ovm_size < 0 or __ovm_size % 1 ~= 0 or __ovm_size > __ovm_length - __ovm_offset then __ovm_error('', 0) end
end
local function __ovm_u8()
    __ovm_need(1)
    local __ovm_value = __ovm_buffer.readu8(__ovm_bytes, __ovm_offset)
    __ovm_offset = __ovm_offset + 1
    return __ovm_value
end
local function __ovm_u32()
    __ovm_need(4)
    local __ovm_value = __ovm_buffer.readu32(__ovm_bytes, __ovm_offset)
    __ovm_offset = __ovm_offset + 4
    return __ovm_value
end
local function __ovm_text(__ovm_cap)
    local __ovm_size = __ovm_u32()
    if __ovm_cap and __ovm_size>__ovm_cap then __ovm_error('',0) end
    __ovm_need(__ovm_size)
    local __ovm_value = __ovm_buffer.readstring(__ovm_bytes, __ovm_offset, __ovm_size)
    __ovm_offset = __ovm_offset + __ovm_size
    return __ovm_value
end
@LOADERHELPERS@
__ovm_need(8)
if __ovm_buffer.readstring(__ovm_bytes, 0, 7) ~= 'VERITY_' or __ovm_buffer.readu8(__ovm_bytes, 7) ~= @WIREVERSION@ then __ovm_error('', 0) end
__ovm_offset = 8
@WIREFLAGS@
local __ovm_count = __ovm_counted(1,__ovm_limits.prototypes)
if __ovm_count==0 then __ovm_error('',0) end
local __ovm_protos = {}
local __ovm_totalconstants,__ovm_totalinstructions=0,0
@COMPACTSIZES@
@BYTECODEHELPERS@
for __ovm_id = 1, __ovm_count do
    local __ovm_p = {id=__ovm_id, params={}, upvalues={}, children={}, constants={}}
@PROTOHEADER@
    local __ovm_n = __ovm_counted(4,__ovm_limits.params)
    for __ovm_i = 1, __ovm_n do __ovm_p.params[__ovm_i] = __ovm_u32() end
    local __ovm_vararg = __ovm_u8()
    if __ovm_vararg>1 then __ovm_error('',0) end
    __ovm_p.vararg = __ovm_vararg == 1
    __ovm_p.slots = __ovm_limit(__ovm_u32(),__ovm_limits.slots)
    __ovm_p.registers = __ovm_limit(__ovm_u32(),__ovm_limits.registers)
@BOXEDLOAD@
    __ovm_n = __ovm_counted(5,__ovm_limits.upvalues)
    for __ovm_i = 1, __ovm_n do
        local __ovm_kind, __ovm_index = __ovm_u8(), __ovm_u32()
        if __ovm_kind ~= 1 and __ovm_kind ~= 2 then __ovm_error('', 0) end
        __ovm_p.upvalues[__ovm_i] = {kind=__ovm_kind, index=__ovm_index}
    end
    __ovm_n = __ovm_counted(4,__ovm_limits.children)
    for __ovm_i = 1, __ovm_n do __ovm_p.children[__ovm_i] = __ovm_u32() end
    __ovm_n = __ovm_counted(1,__ovm_limits.constants)
    __ovm_p.constantCount=__ovm_n
    __ovm_totalconstants=__ovm_limit(__ovm_totalconstants+__ovm_n,__ovm_limits.totalConstants)
@CONSTANTLOAD@
    __ovm_p.count = __ovm_limit(__ovm_u32(),__ovm_limits.instructions)
    if __ovm_p.count==0 then __ovm_error('',0) end
    __ovm_totalinstructions=__ovm_limit(__ovm_totalinstructions+__ovm_p.count,__ovm_limits.totalInstructions)
@DEBUGLOAD@
@CODELOAD@
@MASKONLOAD@
@CODEVALIDATE@
@GUARDPREPARE@
    __ovm_protos[__ovm_id] = __ovm_p
end
if __ovm_offset ~= __ovm_length then __ovm_error('', 0) end
local __ovm_entry = __ovm_protos[@ENTRY@]
if not __ovm_entry then __ovm_error('', 0) end
@POSTLOAD@
@CONSTANTHELPER@
@GUARDDIAGNOSTIC@
@GUARDLOADED@
@BLOCKHELPERS@
@CHECKEDINSTRUCTION@
@CLOSUREHELPERS@
local __ovm_run
@VALIDBUFFER@
__ovm_run = function(__ovm_p, __ovm_u, __ovm_args, __ovm_env)
    local __ovm_l, __ovm_r = {}, {}
@SCHEDULERBINDING@
@CACHEINIT@
@FRAMEINFO@
@GUARDFRAME@
@HOOKCHECK@
@INSTRUCTIONFRAME@
    local __ovm_params = #__ovm_p.params
    for __ovm_i = 1, __ovm_params do
        local __ovm_slot = __ovm_p.params[__ovm_i]
        if @PARAMBOXED@ then __ovm_l[__ovm_slot] = {__ovm_args[__ovm_i]}
        else __ovm_l[__ovm_slot] = __ovm_args[__ovm_i] end
    end
    local __ovm_v = {n=0}
    if __ovm_p.vararg then
        __ovm_v.n = __ovm_args.n - __ovm_params
        if __ovm_v.n < 0 then __ovm_v.n = 0 end
        for __ovm_i = 1, __ovm_v.n do __ovm_v[__ovm_i] = __ovm_args[__ovm_params + __ovm_i] end
    end
    local __ovm_pc, __ovm_junk = 1, @SEED@
@DEBUGSTART@
    while true do
@CHECKPOINT@
@PCVALIDATE@
@DEBUGSITE@
@INSTRUCTIONSTART@
@FETCHINSTRUCTION@
@VALIDATEOP@
@READOPERANDS@
        local __ovm_instructionpc = __ovm_pc
        __ovm_pc = __ovm_pc + 1
@DISPATCH@
    end
@DEBUGEND@
end
return __ovm_run(__ovm_entry, {}, __ovm_pack(...), __ovm_entryenv)
end)(getfenv(), ...)
]=]

local base91Decoder = [=[
local __ovm_encoded = @ENCODED@
local __ovm_byte, __ovm_digits, __ovm_alphabet = string.byte, {}, {}
if #__ovm_encoded ~= @TEXTSIZE@ or string.sub(__ovm_encoded, 1, 7) ~= 'VERITY_' then __ovm_error('', 0) end
for __ovm_i = 33, 126 do
    if __ovm_i ~= 34 and __ovm_i ~= 39 and __ovm_i ~= 92 then __ovm_alphabet[#__ovm_alphabet + 1] = __ovm_i end
end
local __ovm_alphabetstate = @ALPHABETSEED@
for __ovm_i = 91, 2, -1 do
    __ovm_alphabetstate = (__ovm_alphabetstate * 48271) % 2147483647
    local __ovm_j = 1 + __ovm_alphabetstate % __ovm_i
    __ovm_alphabet[__ovm_i], __ovm_alphabet[__ovm_j] = __ovm_alphabet[__ovm_j], __ovm_alphabet[__ovm_i]
end
for __ovm_i = 1, 91 do __ovm_digits[__ovm_alphabet[__ovm_i]] = __ovm_i - 1 end
local __ovm_encrypted = __ovm_buffer.create(@PAYLOADSIZE@)
local __ovm_queue, __ovm_bits, __ovm_low, __ovm_write = 0, 0, -1, 0
for __ovm_i = 8, #__ovm_encoded do
    local __ovm_digit = __ovm_digits[__ovm_byte(__ovm_encoded, __ovm_i)]
    if __ovm_digit == nil then __ovm_error('', 0) end
    if __ovm_low < 0 then __ovm_low = __ovm_digit
    else
        local __ovm_word = __ovm_low + __ovm_digit * 91
        __ovm_low = -1
        __ovm_queue = __ovm_queue + __ovm_word * 2 ^ __ovm_bits
        __ovm_bits = __ovm_bits + (__ovm_word % 8192 > 88 and 13 or 14)
        while __ovm_bits >= 8 do
            if __ovm_write >= __ovm_buffer.len(__ovm_encrypted) then __ovm_error('', 0) end
            __ovm_buffer.writeu8(__ovm_encrypted, __ovm_write, __ovm_queue % 256)
            __ovm_write = __ovm_write + 1
            __ovm_queue = __ovm_floor(__ovm_queue / 256)
            __ovm_bits = __ovm_bits - 8
        end
    end
end
if __ovm_low >= 0 then
    if __ovm_write >= __ovm_buffer.len(__ovm_encrypted) then __ovm_error('', 0) end
    __ovm_buffer.writeu8(__ovm_encrypted, __ovm_write, (__ovm_queue + __ovm_low * 2 ^ __ovm_bits) % 256)
    __ovm_write = __ovm_write + 1
end
if __ovm_write ~= __ovm_buffer.len(__ovm_encrypted) then __ovm_error('', 0) end
__ovm_encoded, __ovm_digits, __ovm_alphabet = nil, nil, nil
]=]

local decompressor = [=[
local __ovm_packed = __ovm_bytes
local __ovm_packedlength = __ovm_length
if __ovm_packedlength < 8 or __ovm_buffer.readstring(__ovm_packed, 0, 4) ~= 'VLZ1' then __ovm_error('', 0) end
local __ovm_expected = __ovm_buffer.readu32(__ovm_packed, 4)
if __ovm_expected ~= @UNPACKEDSIZE@ then __ovm_error('', 0) end
if __ovm_expected > __ovm_limits.payloadBytes then __ovm_error('',0) end
if __ovm_expected > (__ovm_packedlength - 8) * 259 then __ovm_error('', 0) end
__ovm_bytes = __ovm_buffer.create(__ovm_expected)
local __ovm_input, __ovm_output = 8, 0
while __ovm_output < __ovm_expected do
    if __ovm_input >= __ovm_packedlength then __ovm_error('', 0) end
    local __ovm_control = __ovm_buffer.readu8(__ovm_packed, __ovm_input)
    __ovm_input = __ovm_input + 1
    for __ovm_bitindex = 0, 7 do
        if __ovm_output >= __ovm_expected then break end
        if __ovm_bit.band(__ovm_control, __ovm_bit.lshift(1, __ovm_bitindex)) == 0 then
            if __ovm_input >= __ovm_packedlength then __ovm_error('', 0) end
            __ovm_buffer.writeu8(__ovm_bytes, __ovm_output, __ovm_buffer.readu8(__ovm_packed, __ovm_input))
            __ovm_input, __ovm_output = __ovm_input + 1, __ovm_output + 1
        else
            if __ovm_input + 3 > __ovm_packedlength then __ovm_error('', 0) end
            local __ovm_distance = __ovm_buffer.readu16(__ovm_packed, __ovm_input)
            local __ovm_runlength = __ovm_buffer.readu8(__ovm_packed, __ovm_input + 2) + 4
            __ovm_input = __ovm_input + 3
            if __ovm_distance == 0 or __ovm_distance > __ovm_output or __ovm_runlength > __ovm_expected - __ovm_output then __ovm_error('', 0) end
            for __ovm_i = 1, __ovm_runlength do
                __ovm_buffer.writeu8(__ovm_bytes, __ovm_output, __ovm_buffer.readu8(__ovm_bytes, __ovm_output - __ovm_distance))
                __ovm_output = __ovm_output + 1
            end
        end
    end
end
if __ovm_input ~= __ovm_packedlength then __ovm_error('', 0) end
__ovm_length = __ovm_expected
__ovm_packed = nil
]=]

function runtime.render(config)
    assert(type(config) == 'table', 'runtime config must be a table')
    assert(type(config.payload) == 'string', 'runtime payload must be a string')
    assert(type(config.seed) == 'number' and config.seed >= 0 and config.seed < 4294967296 and config.seed % 1 == 0, 'invalid runtime seed')
    assert(type(config.checksum) == 'number' and config.checksum >= 0 and config.checksum < 4294967296 and config.checksum % 1 == 0, 'invalid runtime checksum')
    assert(type(config.opcodes) == 'table', 'runtime opcode map is required')
    local native=nativeHelpers.new(config.nativeHelpers,config.nativeCooperative)
    local scheduling=scheduler.render(config)
    local checkedFetch=config.antiTamper==true
    local frameFetch=fetch.render(config,native)
    local randomState = config.seed % 2147483647
    if randomState == 0 then randomState = 1 end
    local function random(lo, hi)
        if config.rng then return config.rng:int(lo, hi) end
        randomState = randomState * 48271 % 2147483647
        return lo + randomState % (hi - lo + 1)
    end
    local function number(value)
        local salt = random(1, 16383)
        return '(' .. string.format('%.0f', value + salt) .. '-' .. tostring(salt) .. ')'
    end
    local order, seenNames, seenIds, entries = {}, {}, {}, {}
    if config.order then
        for _, name in ipairs(config.order) do
            assert(handlers[name] and not seenNames[name], 'invalid runtime dispatch order')
            seenNames[name] = true
            order[#order + 1] = name
        end
    else
        for name in pairs(handlers) do if config.opcodes[name]~=nil then order[#order + 1] = name end end
        table.sort(order)
    end
    for _, name in ipairs(order) do
        local opcode = config.opcodes[name]
        assert(type(opcode) == 'number' and opcode >= 0 and opcode <= 255 and opcode % 1 == 0, 'invalid opcode: ' .. name)
        local aliases = config.aliases and config.aliases[name] or {opcode}
        assert(type(aliases) == 'table' and #aliases > 0, 'invalid runtime opcode aliases')
        assert(aliases[1] == opcode, 'opcode must equal its first alias')
        for _, alias in ipairs(aliases) do
            assert(type(alias) == 'number' and alias >= 0 and alias <= 255 and alias % 1 == 0, 'invalid runtime opcode alias')
            assert(not seenIds[alias], 'duplicate runtime opcode')
            seenIds[alias] = true
            entries[#entries + 1] = {opcode=alias, name=name}
        end
    end
    assert(#entries > 0, 'runtime needs at least one opcode')
    table.sort(entries, function(left, right) return left.opcode < right.opcode end)
    local aliasLeaves, grouped = #entries, {}
    for _, entry in ipairs(entries) do
        local previous = grouped[#grouped]
        if previous and previous.name == entry.name then previous.maximum = entry.opcode
        else grouped[#grouped + 1] = {opcode=entry.opcode, maximum=entry.opcode, name=entry.name} end
    end
    entries = grouped
    local renderedHandlers, operandReads, variants = {}, {}, {}
    local integrity
    local hookSetup,hookCheck=guards.hooks(config.antiHooks,'__ovm_entryenv')
    if hookSetup~='' then
        local captures={'__ovm_entryenv','__ovm_guardrefs','__ovm_guarderror'}
        for _,name in ipairs({'buffer','bit32','math','table','string'}) do captures[#captures+1]='__ovm_guardlib_'..name end
        hookSetup=native:lift(hookSetup,'__ovm_guardhooks',captures)
    end
    local function handler(name)
        if renderedHandlers[name] then return renderedHandlers[name] end
        local body = handlers[name]
        if name=='CLOSURE' and native.enabled then
            body='__ovm_r[__ovm_a]=__ovm_makeclosure(__ovm_p,__ovm_l,__ovm_u,__ovm_b,__ovm_env,__ovm_run)'
        elseif name == 'OPAQUE' then
            local identities = {
                '(__ovm_x + __ovm_y) * (__ovm_x + __ovm_y) == __ovm_x * __ovm_x + 2 * __ovm_x * __ovm_y + __ovm_y * __ovm_y',
                '(__ovm_x - __ovm_y) * (__ovm_x - __ovm_y) == __ovm_x * __ovm_x - 2 * __ovm_x * __ovm_y + __ovm_y * __ovm_y',
                '(__ovm_x + __ovm_y) * (__ovm_x - __ovm_y) == __ovm_x * __ovm_x - __ovm_y * __ovm_y',
                '(__ovm_x * (__ovm_x + 1)) % 2 == 0 and (__ovm_y * (__ovm_y + 1)) % 2 == 0',
            }
            body = 'local __ovm_x, __ovm_y = __ovm_c, __ovm_d\nif ' .. identities[random(1, #identities)] .. " then __ovm_pc = __ovm_b else __ovm_error('', 0) end"
        elseif name == 'NOP' then
            local variants = {
                '__ovm_bxor((__ovm_junk + __ovm_a + __ovm_b) % 4294967296, __ovm_c, __ovm_d)',
                '(__ovm_bxor(__ovm_junk, __ovm_a, __ovm_c) + __ovm_b + __ovm_d) % 4294967296',
                '__ovm_bxor((__ovm_junk * 33 + __ovm_a) % 4294967296, (__ovm_b + __ovm_c + __ovm_d) % 4294967296)',
                '(__ovm_bxor(__ovm_junk, __ovm_a) + __ovm_bxor(__ovm_b, __ovm_c, __ovm_d)) % 4294967296',
            }
            body = '__ovm_junk = ' .. variants[random(1, #variants)]
        end
        local ids, operand, total
        if name == 'BIN' then ids, operand, total = config.binaryIds, '__ovm_d', 14
        elseif name == 'UN' then ids, operand, total = config.unaryIds, '__ovm_c', 3 end
        if ids then
            local used = {}
            for id = 1, total do
                local value = ids[id]
                assert(type(value) == 'number' and value >= 0 and value < 4294967296 and value % 1 == 0 and not used[value], 'invalid runtime operator mapping')
                used[value] = true
            end
        end
        if operand then
            local prefix, branches, ending = {}, {}, nil
            for line in body:gmatch('[^\n]+') do
                local id, statement = line:match('^if ' .. operand .. ' == (%d+) then (.*)$')
                if not id then id, statement = line:match('^elseif ' .. operand .. ' == (%d+) then (.*)$') end
                if id then branches[#branches + 1] = {id=tonumber(id), statement=statement}
                elseif line:match('^else ') then ending = line
                else prefix[#prefix + 1] = line end
            end
            assert(#branches == total and ending, 'invalid operator handler template')
            for i = #branches, 2, -1 do
                local at = random(1, i)
                branches[i], branches[at] = branches[at], branches[i]
            end
            for i, branch in ipairs(branches) do
                prefix[#prefix + 1] = (i == 1 and 'if ' or 'elseif ') .. operand .. ' == ' .. number(ids and ids[branch.id] or branch.id) .. ' then ' .. branch.statement
            end
            prefix[#prefix + 1] = ending
            body = table.concat(prefix, '\n')
        end
        -- Equivalent bodies vary storage access without changing user evaluation order.
        local variant=random(1,3)
        if variant==2 then
            body='local __ovm_regs = __ovm_r\n'..body:gsub('__ovm_r%[','__ovm_regs[')
        elseif variant==3 and not body:find('\n',1,true) then
            local target,value=body:match('^(.-) = (.+)$')
            if target and target:match('^__ovm_[%w_]+') then body='local __ovm_value = '..value..'\n'..target..' = __ovm_value' end
        end
        variants[name]=variant
        local reads={}
        local checkedFields=(config.antiTamper and not config.compact) and {'a','b','c','d'} or instructions.specs[name].fields
        if not native.enabled and not checkedFetch then
            for _,field in ipairs(checkedFields) do reads[#reads+1]=operandReads[name][field] end
        end
        local verified=''
        if config.antiTamper then
            local used,terms={},{'__ovm_op ~= __ovm_expected[1]'}
            for _,field in ipairs(checkedFields) do used[field]=true end
            for index,field in ipairs({'a','b','c','d'}) do terms[#terms+1]=(used[field] and '__ovm_'..field or '0')..' ~= __ovm_expected['..(index+1)..']' end
            local at=config.lazyInstructions and '__ovm_checkindex' or '__ovm_instructionpc'
            local values={'__ovm_expected','__ovm_op'}
            for _,field in ipairs({'a','b','c','d'}) do values[#values+1]=used[field] and '__ovm_'..field or '0' end
            verified=(frameFetch.enabled and '' or ('local __ovm_expected=__ovm_checks['..at..']\n'))..'__ovm_guardtuple('..table.concat(values,',')..')\n'
        end
        if hookCheck~='' then
            if name=='RETURN' or name=='RETURN0' or name=='RETURN1' then body=hookCheck..'\n'..body
            elseif name=='CALL' or name=='CALL1' or name=='CALL0' or name=='CALLF0' or name=='CALLF1' or name=='CALLFN' or name:match('^CALLF[2-6]$') or name=='GETMETHOD' or name=='ITERPREP' then body=body..'\n'..hookCheck
            elseif name=='BIN' then body=body.."\nif __ovm_type(__ovm_x)=='table' or __ovm_type(__ovm_x)=='userdata' or __ovm_type(__ovm_y)=='table' or __ovm_type(__ovm_y)=='userdata' then "..hookCheck..' end'
            elseif name=='UN' or name=='TOSTRING' then
                body="local __ovm_checkhooks = __ovm_type(__ovm_r[__ovm_b])=='table' or __ovm_type(__ovm_r[__ovm_b])=='userdata'\n"..body..'\nif __ovm_checkhooks then '..hookCheck..' end'
            elseif name=='GETTABLE' then
                body='local __ovm_checkhooks = __ovm_getmetatable(__ovm_r[__ovm_b]) ~= nil\n'..body..'\nif __ovm_checkhooks then '..hookCheck..' end'
            elseif name=='SETTABLE' then
                body='local __ovm_checkhooks = __ovm_getmetatable(__ovm_r[__ovm_a]) ~= nil\n'..body..'\nif __ovm_checkhooks then '..hookCheck..' end'
            elseif name=='GETGLOBAL' or name=='SETGLOBAL' then
                body='local __ovm_checkhooks = __ovm_getmetatable(__ovm_env) ~= nil\n'..body..'\nif __ovm_checkhooks then '..hookCheck..' end'
            end
        end
        body=table.concat(reads,'\n')..'\n'..verified..body
        renderedHandlers[name] = body
        return body
    end
    local function tree(lo, hi, depth)
        local indent = string.rep('    ', depth)
        if lo == hi then return indent .. 'do\n' .. handler(entries[lo].name) .. '\n' .. indent .. 'end' end
        local middle = math.floor((lo + hi) / 2)
        local threshold = number(random(entries[middle].maximum + 1, entries[middle + 1].opcode))
        local left, right = tree(lo, middle, depth + 1), tree(middle + 1, hi, depth + 1)
        local comparison = '<'
        if random(0, 1) == 1 then comparison, left, right = '>=', right, left end
        return indent .. 'if __ovm_op ' .. comparison .. ' ' .. threshold .. ' then\n' .. left .. '\n' .. indent .. 'else\n' .. right .. '\n' .. indent .. 'end'
    end
    local dispatch
    local layout = config.layout or {op=0,a=1,b=5,c=9,d=13}
    local occupied = {}
    for _, field in ipairs({'op','a','b','c','d'}) do
        local offset, width = layout[field], field == 'op' and 1 or 4
        assert(type(offset) == 'number' and offset >= 0 and offset + width <= 17 and offset % 1 == 0, 'invalid instruction layout')
        for at = offset, offset + width - 1 do
            assert(not occupied[at], 'overlapping instruction layout')
            occupied[at] = true
        end
    end
    local maskWrites = {}
    if config.maskOnLoad then
        assert(type(config.operandKeys) == 'table' and type(config.operandStrides) == 'table', 'mask-on-load requires operand keys and strides')
    end
    for _,name in ipairs(order) do
      operandReads[name]={}
      local fieldOrder=(not config.compact and config.antiTamper) and {'a','b','c','d'} or serialize.fieldOrder(name,config.fields)
      for index,field in ipairs(fieldOrder) do
        local expression = '__ovm_buffer.readu32(__ovm_instructionbytes, __ovm_at + ' .. number(layout[field]) .. ')'
        if config.compact then expression='__ovm_read(__ovm_instructionbytes, __ovm_at + 1 + '..tostring(index-1)..'*__ovm_width)' end
        if (config.version or 1)>=3 or config.operandKeys or config.operandStrides then
            local key = config.operandKeys and config.operandKeys[field] or 0
            local stride = config.operandStrides and config.operandStrides[field] or 0
            assert(type(key) == 'number' and key >= 0 and key < 4294967296 and key % 1 == 0, 'invalid operand mask key')
            assert(type(stride) == 'number' and stride >= 0 and stride < 4294967296 and stride % 1 == 0, 'invalid operand mask stride')
            local keys=(config.version or 1)>=3 and '__ovm_p.operandKeys' or '__ovm_fieldkeys'
            local strides=(config.version or 1)>=3 and '__ovm_p.operandStrides' or '__ovm_fieldstrides'
            expression = '(' .. expression .. '-'..keys..'['..tostring(instructions.positions[field])..']-__ovm_instructionpc*'..strides..'['..tostring(instructions.positions[field])..']-__ovm_salt)%'..(config.compact and '__ovm_modulus' or '4294967296')
        end
        operandReads[name][field] = '        local __ovm_' .. field .. ' = ' .. expression
      end
    end
    -- Legacy masks cover every field once regardless of which handlers are retained.
    if config.maskOnLoad and not config.compact then
        for _,field in ipairs({'a','b','c','d'}) do
            local at='__ovm_instruction + '..number(layout[field])
            maskWrites[#maskWrites+1]='        __ovm_buffer.writeu32(__ovm_bytes, '..at..', (__ovm_buffer.readu32(__ovm_bytes, '..at..')+'..number(config.operandKeys[field])..'+__ovm_site*'..number(config.operandStrides[field])..'+__ovm_p.id*5153)%4294967296)'
        end
    end
    integrity=guards.integrity(config,config.opcodes,instructions.specs,serialize.fieldOrder,quoteBytes,number)
    dispatch=tree(1,#entries,2)
    local validKey, validMask = random(0, 255), {}
    for byte = 0, 31 do
        local mask = 0
        for bit = 0, 7 do if seenIds[byte * 8 + bit] then mask = mask + 2 ^ bit end end
        local xor, a, b, place = 0, mask, validKey, 1
        for _ = 1, 8 do
            if a % 2 ~= b % 2 then xor = xor + place end
            a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
        end
        validMask[#validMask + 1] = string.char(xor)
    end
    local decompress = ''
    if config.compressed then
        assert(type(config.unpackedSize) == 'number' and config.unpackedSize >= 0 and config.unpackedSize < 4294967296 and config.unpackedSize % 1 == 0, 'invalid unpacked payload length')
        local unpackedSize = number(config.unpackedSize)
        decompress = decompressor:gsub('@UNPACKEDSIZE@', function() return unpackedSize end)
    end
    assert(config.transport == nil or config.transport == 'auto' or config.transport == 'base91' or config.transport == 'literal', 'invalid payload transport')
    local alphabetSeed = config.alphabetSeed or random(1, 2147483646)
    local alphabet = base91.alphabet(alphabetSeed)
    local encoded = 'VERITY_' .. base91.encode(config.payload, alphabet)
    local encodedValues = {
        ALPHABETSEED=number(alphabetSeed), ENCODED=quoteBytes(encoded),
        PAYLOADSIZE=number(#config.payload), TEXTSIZE=number(#encoded),
    }
    local transport = base91Decoder:gsub('@([A-Z]+)@', function(key) return assert(encodedValues[key]) end)
    local transportKind, encodedBytes = 'base91', #encoded
    if config.transport == 'literal' then
        local literal = quoteBytes('VERITY_' .. config.payload)
        transport, transportKind, encodedBytes = 'local __ovm_encrypted = __ovm_buffer.fromstring(string.sub(' .. literal .. ', 8))', 'literal', #literal
    elseif native.enabled then
        local values={ALPHABETSEED='__ovm_alphabetseed',ENCODED='__ovm_encodedinput',
            PAYLOADSIZE='__ovm_payloadsize',TEXTSIZE='__ovm_textsize'}
        local body=base91Decoder:gsub('@([A-Z]+)@',function(key) return assert(values[key]) end)
        body=body:gsub('string.byte','__ovm_stringbyte'):gsub('string.sub','__ovm_stringsub')
        transport=native:block(body,
            {'__ovm_encodedinput','__ovm_alphabetseed','__ovm_payloadsize','__ovm_textsize',
                '__ovm_buffer','__ovm_floor','__ovm_error','__ovm_stringbyte','__ovm_stringsub'},
            {encodedValues.ENCODED,encodedValues.ALPHABETSEED,encodedValues.PAYLOADSIZE,encodedValues.TEXTSIZE,
                '__ovm_buffer','__ovm_floor','__ovm_error','string.byte','string.sub'},
            {'__ovm_encrypted'})
    end
    local cipherDecoder, cipherValues
    if config.cipher then
        local key, multiplier = config.cipher.key, config.cipher.multiplier
        assert(type(key) == 'number' and key >= 1 and key < 2147483647 and key % 1 == 0, 'invalid cipher key')
        assert(type(multiplier) == 'number' and multiplier >= 10001 and multiplier <= 100000 and multiplier % 1 == 0, 'invalid cipher multiplier')
        cipherDecoder = [=[
local __ovm_cipherstate = @KEY@
for __ovm_i = 0, __ovm_length - 1 do
    __ovm_cipherstate = (__ovm_cipherstate * @MULTIPLIER@) % 2147483647
    local __ovm_plain = (__ovm_buffer.readu8(__ovm_encrypted, __ovm_i) - __ovm_floor(__ovm_cipherstate / 65536) % 256) % 256
    __ovm_buffer.writeu8(__ovm_bytes, __ovm_i, __ovm_plain)
    __ovm_cipherstate = (__ovm_cipherstate + __ovm_plain + __ovm_i % 251) % 2147483647
    if __ovm_cipherstate == 0 then __ovm_cipherstate = 1 end
end]=]
        cipherValues = {KEY=number(key), MULTIPLIER=number(multiplier)}
    else
        cipherDecoder = [=[
for __ovm_i = 0, __ovm_length - 1 do
    local __ovm_plain = (__ovm_buffer.readu8(__ovm_encrypted, __ovm_i) - ((@SEED@ + __ovm_i * 73 + __ovm_floor(__ovm_i / 256) * 19) % 256)) % 256
    __ovm_buffer.writeu8(__ovm_bytes, __ovm_i, __ovm_plain)
end]=]
        cipherValues = {SEED=number(config.seed)}
    end
    local cipherTemplate=cipherDecoder
    cipherDecoder = cipherTemplate:gsub('@([A-Z]+)@', function(key) return assert(cipherValues[key]) end)
    if native.enabled then
        local values={KEY='__ovm_cipherkey',MULTIPLIER='__ovm_ciphermultiplier',SEED='__ovm_cipherkey'}
        -- Keep per-build secrets as packed constant arguments, not in helpers.
        local body=cipherTemplate:gsub('@([A-Z]+)@',function(key) return assert(values[key]) end)
        cipherDecoder=native:block(body,
            {'__ovm_buffer','__ovm_floor','__ovm_encrypted','__ovm_bytes','__ovm_length','__ovm_cipherkey','__ovm_ciphermultiplier'},
            {'__ovm_buffer','__ovm_floor','__ovm_encrypted','__ovm_bytes','__ovm_length',
                cipherValues.KEY or cipherValues.SEED,cipherValues.MULTIPLIER or 'nil'})
        if decompress~='' then
            local body=decompress:gsub('if __ovm_expected ~= .- then','if __ovm_expected ~= __ovm_unpackedsize then',1)
            body=body:gsub('__ovm_limits.payloadBytes','__ovm_payloadcap')
            decompress=native:block(body,
                {'__ovm_buffer','__ovm_bit','__ovm_error','__ovm_payloadcap','__ovm_bytes','__ovm_length','__ovm_unpackedsize'},
                {'__ovm_buffer','__ovm_bit','__ovm_error','__ovm_limits.payloadBytes','__ovm_bytes','__ovm_length',number(config.unpackedSize)},
                {'__ovm_bytes','__ovm_length'},false)
        end
    end
    local version=config.version or 1
    assert(version==1 or version==2 or version==3,'invalid runtime wire version')
    assert(version>=3 or not (config.lazyInstructions or config.perPrototypeOpcodes),'wire v3 required for instruction protection')
    local flags=(config.compact and 1 or 0)+(config.lazyConstants and 2 or 0)+(config.debug and 4 or 0)+(config.perPrototypeOpcodes and 8 or 0)+(config.lazyInstructions and 16 or 0)
    local boxedLoad=''
    if version>=2 then boxedLoad=[=[
    __ovm_p.boxed = {}
    local __ovm_boxes = __ovm_counted(4,__ovm_p.slots)
    for __ovm_i = 1, __ovm_boxes do
        local __ovm_slot = __ovm_u32()
        if __ovm_slot < 1 or __ovm_slot > __ovm_p.slots or __ovm_p.boxed[__ovm_slot] then __ovm_error('', 0) end
        __ovm_p.boxed[__ovm_slot] = true
    end]=] end
    local constantLoad=[=[
    for __ovm_i = 1, __ovm_n do
        local __ovm_tag = __ovm_u8()
        local __ovm_value
        if __ovm_tag == 0 then __ovm_value = nil
        elseif __ovm_tag == 1 then __ovm_value = false
        elseif __ovm_tag == 2 then __ovm_value = true
        elseif __ovm_tag == 3 or __ovm_tag == 4 then
            __ovm_value = __ovm_text(__ovm_limits.constantBytes)
            if __ovm_tag == 3 then
                if __ovm_value == 'inf' then __ovm_value = 1 / 0
                elseif __ovm_value == '-inf' then __ovm_value = -1 / 0
                elseif __ovm_value == 'nan' then __ovm_value = 0 / 0
                else __ovm_value = __ovm_tonumber(__ovm_value)
                    if __ovm_value == nil then __ovm_error('', 0) end
                end
            end
        else __ovm_error('', 0) end
        __ovm_p.constants[__ovm_i] = __ovm_value
    end]=]
    local constantHelper='local function __ovm_constant(__ovm_p, __ovm_index) return __ovm_p.constants[__ovm_index] end'
    if version>=2 then
        constantLoad=[=[
    __ovm_p.cache = {}
    for __ovm_i = 1, __ovm_n do
        local __ovm_tag = __ovm_u8()
        if __ovm_tag > 5 then __ovm_error('', 0) end
        local __ovm_descriptor = {tag=__ovm_tag}
        if __ovm_tag == 5 then
            local __ovm_width = __ovm_u8()
            if __ovm_width ~= 1 and __ovm_width ~= 2 and __ovm_width ~= 4 then __ovm_error('', 0) end
            __ovm_need(__ovm_width)
            local __ovm_reader = __ovm_width == 1 and __ovm_buffer.readu8 or __ovm_width == 2 and __ovm_buffer.readu16 or __ovm_buffer.readu32
            __ovm_descriptor.raw = __ovm_reader(__ovm_bytes, __ovm_offset)
            __ovm_descriptor.modulus = 2 ^ (__ovm_width * 8)
            __ovm_offset = __ovm_offset + __ovm_width
        elseif __ovm_tag == 3 or __ovm_tag == 4 then
            __ovm_descriptor.size = __ovm_limit(__ovm_u32(),__ovm_limits.constantBytes)
            @CONSTHASH@
            __ovm_need(__ovm_descriptor.size)
            __ovm_descriptor.offset = __ovm_offset
            __ovm_offset = __ovm_offset + __ovm_descriptor.size
        end
        __ovm_p.constants[__ovm_i] = __ovm_descriptor
    end]=]
        constantLoad=constantLoad:gsub('@CONSTHASH@',function() return config.lazyConstants and '__ovm_descriptor.hash = __ovm_u32()' or '' end)
        constantHelper=[=[
local function __ovm_constant(__ovm_p, __ovm_index, __ovm_cache)
    local __ovm_cached = (__ovm_p.eager or __ovm_cache) and (__ovm_p.eager or __ovm_cache)[__ovm_index]
    if __ovm_cached then return __ovm_cached[1] end
    local __ovm_descriptor = __ovm_p.constants[__ovm_index]
    if not __ovm_descriptor then __ovm_error('', 0) end
    local __ovm_tag, __ovm_value = __ovm_descriptor.tag, nil
    if __ovm_tag == 1 then __ovm_value = false
    elseif __ovm_tag == 2 then __ovm_value = true
    elseif __ovm_tag == 5 then
        local __ovm_zigzag = @INTEGERDECRYPT@
        __ovm_value = __ovm_zigzag % 2 == 0 and __ovm_zigzag / 2 or -(__ovm_zigzag + 1) / 2
    elseif __ovm_tag == 3 or __ovm_tag == 4 then
        __ovm_limit(__ovm_descriptor.size,__ovm_limits.constantBytes)
        __ovm_limit(__ovm_descriptor.offset,__ovm_length)
        if __ovm_descriptor.size>__ovm_length-__ovm_descriptor.offset then __ovm_error('',0) end
        @CONSTDECRYPT@
        if __ovm_tag == 3 then
            if __ovm_value == 'inf' then __ovm_value = 1 / 0
            elseif __ovm_value == '-inf' then __ovm_value = -1 / 0
            elseif __ovm_value == 'nan' then __ovm_value = 0 / 0
            else __ovm_value = __ovm_tonumber(__ovm_value)
                if __ovm_value == nil then __ovm_error('', 0) end
            end
        end
    end
    if __ovm_cache then
        local __ovm_cachevalue = {__ovm_value}
        @FREEZECACHE@
        __ovm_cache[__ovm_index] = __ovm_cachevalue
    end
    @CONSTOBSERVER@
    return __ovm_value
end
@EAGERCONSTANTS@]=]
        local constantDecrypt='__ovm_value = __ovm_buffer.readstring(__ovm_bytes, __ovm_descriptor.offset, __ovm_descriptor.size)'
        if config.lazyConstants then
            constantDecrypt=[=[
        local __ovm_state = (@CONSTKEY@ + __ovm_p.id * 8191 + __ovm_index * 131 + __ovm_tag * 17) % 2147483646 + 1
        local __ovm_plainbuffer = __ovm_buffer.create(__ovm_descriptor.size)
        local __ovm_hash = 5381
        for __ovm_i = 0, __ovm_descriptor.size - 1 do
            __ovm_state = (__ovm_state * 48271) % 2147483647
            local __ovm_byte = (__ovm_buffer.readu8(__ovm_bytes, __ovm_descriptor.offset + __ovm_i) - __ovm_floor(__ovm_state / 65536) % 256) % 256
            __ovm_buffer.writeu8(__ovm_plainbuffer, __ovm_i, __ovm_byte)
            __ovm_hash = (__ovm_hash * 33 + __ovm_byte) % 4294967296
            __ovm_state = (__ovm_state + __ovm_byte + __ovm_i % 251) % 2147483647
            if __ovm_state == 0 then __ovm_state = 1 end
        end
        if __ovm_hash ~= __ovm_descriptor.hash then __ovm_error('', 0) end
        __ovm_value = __ovm_buffer.readstring(__ovm_plainbuffer, 0, __ovm_descriptor.size)
        __ovm_plainbuffer = nil]=]
            constantDecrypt=constantDecrypt:gsub('@CONSTKEY@',function() return version>=3 and '__ovm_p.constantSeed' or number(assert(config.constantKey)) end)
            if native.enabled then
                local body=constantDecrypt:gsub('local __ovm_state = .-\n','local __ovm_state = __ovm_constantstate\n',1)
                body='local __ovm_value\n'..body
                body=body:gsub('__ovm_descriptor.size','__ovm_constantsize')
                    :gsub('__ovm_descriptor.offset','__ovm_constantoffset'):gsub('__ovm_descriptor.hash','__ovm_constanthash')
                constantDecrypt=native:block(body,
                    {'__ovm_buffer','__ovm_floor','__ovm_error','__ovm_bytes','__ovm_constantsize','__ovm_constantoffset','__ovm_constanthash','__ovm_constantstate'},
                    {'__ovm_buffer','__ovm_floor','__ovm_error','__ovm_bytes','__ovm_descriptor.size','__ovm_descriptor.offset','__ovm_descriptor.hash',
                        '('..(version>=3 and '__ovm_p.constantSeed' or number(assert(config.constantKey)))..'+__ovm_p.id*8191+__ovm_index*131+__ovm_tag*17)%2147483646+1'},
                    {'__ovm_value'},false)
            end
        end
        local observer=config.debugConstants and ('local __ovm_observer = __ovm_entryenv.__verity_constant\n    if __ovm_type(__ovm_observer) == "function" then __ovm_observer('..tostring(config.layer or 1)..', __ovm_p.id, __ovm_index, __ovm_value) end') or ''
        local eager=config.lazyConstants and '' or [=[
for __ovm_i = 1, __ovm_count do
    local __ovm_p = __ovm_protos[__ovm_i]
    local __ovm_eager = {}
    for __ovm_k = 1, #__ovm_p.constants do __ovm_eager[__ovm_k] = {__ovm_constant(__ovm_p, __ovm_k)} end
    __ovm_p.eager = __ovm_eager
end]=]
        local integerDecrypt=config.lazyConstants and ('(__ovm_descriptor.raw - ( '..(version>=3 and '__ovm_p.constantSeed' or number(assert(config.constantKey)))..' + __ovm_p.id * 8191 + __ovm_index * 131 + 85) % 2147483646 - 1) % __ovm_descriptor.modulus') or '__ovm_descriptor.raw'
        local values={CONSTDECRYPT=constantDecrypt,CONSTOBSERVER=observer,EAGERCONSTANTS=eager,INTEGERDECRYPT=integerDecrypt,
            FREEZECACHE=config.antiTamper and '__ovm_guardfreezeentry(__ovm_cachevalue)' or ''}
        constantHelper=constantHelper:gsub('@([A-Z]+)@',function(key) return assert(values[key]) end)
    end
    local codeLoad=[=[
    __ovm_p.offset = __ovm_offset
    __ovm_need(__ovm_p.count * 17)
    __ovm_offset = __ovm_offset + __ovm_p.count * 17]=]
    local compactSizes=''
    local globalMasks=''
    if config.operandKeys or config.operandStrides then
        local keys,strides={},{}
        for _,field in ipairs({'a','b','c','d'}) do keys[#keys+1]=number(config.operandKeys and config.operandKeys[field] or 0); strides[#strides+1]=number(config.operandStrides and config.operandStrides[field] or 0) end
        globalMasks='local __ovm_fieldkeys = {'..table.concat(keys,',')..'}\nlocal __ovm_fieldstrides = {'..table.concat(strides,',')..'}'
    end
    do
        local sizes={}
        local fieldIds={}
        for i=0,255 do sizes[i+1]=string.char(0) end
        for i=1,256 do fieldIds[i]=string.char(0) end
        for _,entry in ipairs(order) do
            for _,alias in ipairs(config.aliases and config.aliases[entry] or {config.opcodes[entry]}) do
                sizes[alias+1]=string.char(#instructions.specs[entry].fields+1)
                local packedOrder=0
                for index,field in ipairs(serialize.fieldOrder(entry,config.fields)) do packedOrder=packedOrder+(instructions.positions[field]-1)*4^(index-1) end
                fieldIds[alias+1]=string.char(packedOrder)
            end
        end
        compactSizes='local __ovm_instrsizes = __ovm_buffer.fromstring('..quoteBytes(table.concat(sizes))..')\nlocal __ovm_instrorders = __ovm_buffer.fromstring('..quoteBytes(table.concat(fieldIds))..')\nlocal __ovm_sizes = __ovm_instrsizes'
        if config.maskOnLoad then
            compactSizes=compactSizes..'\nlocal __ovm_fieldids = __ovm_instrorders'
        end
        if config.compact then
        codeLoad=[=[
    __ovm_p.width = __ovm_u8()
    if __ovm_p.width ~= 1 and __ovm_p.width ~= 2 and __ovm_p.width ~= 4 then __ovm_error('', 0) end
    __ovm_p.read = __ovm_p.width == 1 and __ovm_buffer.readu8 or __ovm_p.width == 2 and __ovm_buffer.readu16 or __ovm_buffer.readu32
    __ovm_p.modulus = 2 ^ (__ovm_p.width * 8)
    __ovm_p.write = __ovm_p.width == 1 and __ovm_buffer.writeu8 or __ovm_p.width == 2 and __ovm_buffer.writeu16 or __ovm_buffer.writeu32
    __ovm_p.sites = {}
    for __ovm_site = 1, __ovm_p.count do
        __ovm_p.sites[__ovm_site] = __ovm_offset
        __ovm_need(1)
        local __ovm_op = __ovm_decodeopcode(__ovm_p,__ovm_buffer.readu8(__ovm_bytes, __ovm_offset))
        local __ovm_fields = __ovm_buffer.readu8(__ovm_sizes, __ovm_op)
        if __ovm_fields == 0 then __ovm_error('', 0) end
        local __ovm_size = 1 + (__ovm_fields - 1) * __ovm_p.width
        __ovm_need(__ovm_size)
        @COMPACTMASK@
        __ovm_offset = __ovm_offset + __ovm_size
    end]=]
        codeLoad=codeLoad:gsub('@COMPACTMASK@',function() return config.maskOnLoad and [=[
        for __ovm_field = 0, __ovm_fields - 2 do
            local __ovm_id = __ovm_bit.extract(__ovm_buffer.readu8(__ovm_fieldids, __ovm_op), __ovm_field * 2, 2) + 1
            local __ovm_at = __ovm_offset + 1 + __ovm_field * __ovm_p.width
            local __ovm_value = (__ovm_p.read(__ovm_bytes, __ovm_at) + __ovm_fieldkeys[__ovm_id] + __ovm_site * __ovm_fieldstrides[__ovm_id] + __ovm_p.id * 5153) % __ovm_p.modulus
            __ovm_p.write(__ovm_bytes, __ovm_at, __ovm_value)
        end]=] or '' end)
        end
    end
    local debugLoad=config.debug and [=[
    __ovm_p.source, __ovm_p.lines = __ovm_text(), {}
    for __ovm_i = 1, __ovm_p.count do __ovm_p.lines[__ovm_i] = __ovm_u32() end]=] or ''
    local debugEnd=config.debug and [=[
    end
    local __ovm_results = __ovm_pack(__ovm_pcall(__ovm_execute))
    if not __ovm_results[1] then
        __ovm_error(__ovm_tostring(__ovm_results[2]) .. ' [zz7 ' .. __ovm_p.source .. ':' .. __ovm_tostring(__ovm_p.lines[__ovm_site] or 0) .. ' proto=' .. __ovm_tostring(__ovm_p.id) .. ' pc=' .. __ovm_tostring(__ovm_site) .. ']', 0)
    end
    return __ovm_unpack(__ovm_results, 2, __ovm_results.n)]=] or ''
    local cache=config.constantCache or 'prototype'
    assert(cache=='prototype' or cache=='execution' or cache=='none','invalid constant cache')
    local safeLoader=loader.render(config,quoteBytes,number)
    local instructionVM=blockvm.render(config,quoteBytes,number)
    if instructionVM.protection~='' then
        instructionVM.protection=native:lift(instructionVM.protection,'__ovm_blockdigest',
            {'__ovm_buffer','__ovm_floor','__ovm_bxor'})
    end
    if native.enabled and config.lazyInstructions then
        local first=assert(instructionVM.helpers:find('    local __ovm_state=__ovm_key\n',1,true))
        local last=assert(instructionVM.helpers:find('    local __ovm_hash1,__ovm_hash2=',first,true))
        local body=instructionVM.helpers:sub(first,last-1)
            :gsub('__ovm_descriptor.size','__ovm_blocksize'):gsub('__ovm_descriptor.offset','__ovm_blockoffset')
        local call=native:block(body,
            {'__ovm_buffer','__ovm_floor','__ovm_bytes','__ovm_blocksize','__ovm_blockoffset','__ovm_key'},
            {'__ovm_buffer','__ovm_floor','__ovm_bytes','__ovm_descriptor.size','__ovm_descriptor.offset','__ovm_key'},
            {'__ovm_data'})
        instructionVM.helpers=instructionVM.helpers:sub(1,first-1)..call..'\n'..instructionVM.helpers:sub(last)
    end
    constantHelper=nativeHot.apply(native,config,safeLoader,instructionVM,constantHelper)
    local checkedInstruction=''
    if checkedFetch then
        checkedInstruction=[=[
local function __ovm_checkedinstruction(__ovm_data,__ovm_at,__ovm_record)
    local __ovm_raw=__ovm_record[6]
    if __ovm_buffer.readstring(__ovm_data,__ovm_at,#__ovm_raw)~=__ovm_raw then __ovm_error('',0) end
    return __ovm_record[1],__ovm_record[2],__ovm_record[3],__ovm_record[4],__ovm_record[5]
end
]=]
        checkedInstruction=native:lift(checkedInstruction,'__ovm_checkedinstruction',{'__ovm_buffer','__ovm_error'})
        local tupleGuard=[=[
local function __ovm_guardtuple(__ovm_record,__ovm_op,__ovm_a,__ovm_b,__ovm_c,__ovm_d)
    if __ovm_op~=__ovm_record[1] or __ovm_a~=__ovm_record[2] or __ovm_b~=__ovm_record[3]
        or __ovm_c~=__ovm_record[4] or __ovm_d~=__ovm_record[5] then __ovm_error('',0) end
end
]=]
        checkedInstruction=checkedInstruction..'\n'..native:lift(tupleGuard,'__ovm_guardtuple',{'__ovm_error'})
    end
    local closureHelper=closure.render(config,native)
    if config.lazyInstructions then codeLoad=instructionVM.codeLoad end
    local validateCode=''
    if not config.lazyInstructions and not config.antiTamper then
        validateCode='    for __ovm_site=1,__ovm_p.count do\n        __ovm_decodeinstruction(__ovm_p,__ovm_bytes,'..(config.compact and '__ovm_p.sites[__ovm_site]' or '__ovm_p.offset+(__ovm_site-1)*17')..',__ovm_site)\n    end'
    end
    local payloadDigest=''
    if config.payloadDigest1 then
        payloadDigest='local __ovm_payloadhash1,__ovm_payloadhash2=__ovm_blockdigest(__ovm_bytes,0,__ovm_length,'..number(config.payloadDigestKey)..')\nif __ovm_payloadhash1~='..number(config.payloadDigest1)..' or __ovm_payloadhash2~='..number(config.payloadDigest2).." then __ovm_error('',0) end"
    end
    local checksum=[=[
local __ovm_hash=5381
for __ovm_i=0,__ovm_length-1 do
    __ovm_hash=(__ovm_hash*33+__ovm_buffer.readu8(__ovm_bytes,__ovm_i))%4294967296
end
if __ovm_hash~=__ovm_expectedchecksum then __ovm_error('',0) end
]=]
    if native.enabled then
        checksum=native:block(checksum,
            {'__ovm_buffer','__ovm_error','__ovm_bytes','__ovm_length','__ovm_expectedchecksum'},
            {'__ovm_buffer','__ovm_error','__ovm_bytes','__ovm_length',number(config.checksum)})
    else checksum=checksum:gsub('__ovm_expectedchecksum',number(config.checksum)) end
    if scheduling.enabled then
        local function checkpoints(body)
            return body:gsub(' do\n',' do\n'..scheduling.checkpoint..'\n')
        end
        transport,cipherDecoder,decompress=checkpoints(transport),checkpoints(cipherDecoder),checkpoints(decompress)
        checksum,constantHelper=checkpoints(checksum),checkpoints(constantHelper)
        instructionVM.protection,instructionVM.helpers=checkpoints(instructionVM.protection),checkpoints(instructionVM.helpers)
    end
    local substitutions = {
        TRANSPORT = transport,
        TRANSPORTBOUND='if '..number(#config.payload).." > __ovm_limits.payloadBytes then __ovm_error('',0) end",
        CIPHER = cipherDecoder,
        SEED = number(config.seed),
        CHECKSUM = number(config.checksum),
        ENTRY = number(config.entry or 1),
        DISPATCH = dispatch,
        DECOMPRESS = decompress,
        MASKONLOAD = config.maskOnLoad and not config.compact and ('    for __ovm_site = 1, __ovm_p.count do\n        local __ovm_instruction = __ovm_p.offset + (__ovm_site - 1) * 17\n' .. table.concat(maskWrites, '\n') .. '\n    end') or '',
        OFFSETOP = number(config.compact and 0 or layout.op),
        READOPERANDS = '',
        VALIDMASK = quoteBytes(table.concat(validMask)),
        VALIDKEY = number(validKey),
        WIREVERSION=tostring(version),
        WIREFLAGS=version>=2 and ('if __ovm_u8() ~= '..tostring(flags).." then __ovm_error('', 0) end") or '',
        BOXEDLOAD=boxedLoad,
        CONSTANTLOAD=constantLoad,
        CONSTANTHELPER=constantHelper,
        COMPACTSIZES=globalMasks..'\n'..compactSizes,
        CODELOAD=codeLoad,
        PARAMBOXED=version>=2 and '__ovm_p.boxed[__ovm_slot]' or 'true',
        CACHEINIT='local __ovm_cache = '..(cache=='prototype' and '__ovm_p.cache' or cache=='execution' and '{}' or 'nil'),
        FRAMEINFO=frameFetch.enabled and '' or ((config.compact and 'local __ovm_read, __ovm_width, __ovm_modulus = __ovm_p.read, __ovm_p.width, __ovm_p.modulus\n' or '')..'local __ovm_salt = __ovm_p.id * 5153'),
        PCVALIDATE=frameFetch.enabled and '' or "if __ovm_pc<1 or __ovm_pc>__ovm_p.count then __ovm_error('',0) end",
        INSTRUCTIONAT=config.compact and '__ovm_p.sites[__ovm_pc]' or '__ovm_p.offset + (__ovm_pc - 1) * 17',
        INSTRUCTIONSTART=frameFetch.enabled and '' or config.lazyInstructions and instructionVM.at or ('        local __ovm_at='..(config.compact and '__ovm_p.sites[__ovm_pc]' or '__ovm_p.offset + (__ovm_pc - 1) * 17')),
        INSTRUCTIONFRAME=frameFetch.enabled and frameFetch.frame or config.lazyInstructions and instructionVM.frame or 'local __ovm_instructionbytes=__ovm_bytes',
        FETCHINSTRUCTION=frameFetch.enabled and frameFetch.fetch or checkedFetch
            and ('local __ovm_op,__ovm_a,__ovm_b,__ovm_c,__ovm_d=__ovm_checkedinstruction(__ovm_instructionbytes,__ovm_at,__ovm_checks['..(config.lazyInstructions and '__ovm_checkindex' or '__ovm_pc')..'])')
            or native.enabled and 'local __ovm_op,__ovm_a,__ovm_b,__ovm_c,__ovm_d=__ovm_decodeinstruction(__ovm_p,__ovm_instructionbytes,__ovm_at,__ovm_pc)'
            or ('local __ovm_op=__ovm_decodeopcode(__ovm_p,__ovm_buffer.readu8(__ovm_instructionbytes,__ovm_at+'..number(config.compact and 0 or layout.op)..'))'),
        CHECKEDINSTRUCTION=checkedInstruction..'\n'..frameFetch.helpers,
        CLOSUREHELPERS=closureHelper,
        BLOCKHELPERS=instructionVM.helpers,
        BYTECODEHELPERS=instructionVM.decode,
        PROTOHEADER=instructionVM.header,
        PROTECTIONHELPERS=instructionVM.protection,
        LOADERLIMITS=safeLoader.limits,
        LOADERHELPERS=safeLoader.helpers..'\n'..safeLoader.validate,
        POSTLOAD=safeLoader.postload,
        CODEVALIDATE=validateCode,
        PAYLOADDIGEST=payloadDigest,
        PAYLOADCHECKSUM=checksum,
        DEBUGLIB=config.debug and 'local __ovm_pcall, __ovm_tostring = pcall, tostring' or '',
        DEBUGLOAD=debugLoad,
        DEBUGSTART=config.debug and 'local __ovm_site = 1\n    local function __ovm_execute()' or '',
        DEBUGSITE=config.debug and '__ovm_site = __ovm_pc' or '',
        DEBUGEND=debugEnd,
        VALIDATEOP=config.compact and '' or "        if __ovm_bit.band(__ovm_bxor(__ovm_buffer.readu8(__ovm_valid, __ovm_floor(__ovm_op / 8)), "..number(validKey).."), __ovm_bit.lshift(1, __ovm_op % 8)) == 0 then __ovm_error('', 0) end",
        VALIDBUFFER=config.compact and '' or ('local __ovm_valid = __ovm_buffer.fromstring('..quoteBytes(table.concat(validMask))..')'),
        HOOKSETUP=hookSetup,
        HOOKCHECK=hookCheck,
        GUARDSTARTUP=integrity.startup,
        SCHEDULERSETUP=scheduling.setup,
        SCHEDULERBINDING=scheduling.binding or '',
        CHECKPOINT=scheduling.checkpoint,
        GUARDPREPARE=integrity.prepare,
        GUARDFRAME=integrity.frame,
        GUARDLOADED=integrity.loaded,
        GUARDDIAGNOSTIC=config.debugGuards and ('local __ovm_guardobserver = __ovm_entryenv.__verity_guard\nif __ovm_type(__ovm_guardobserver)=="function" then __ovm_guardobserver('..tostring(config.layer or 1)..',__ovm_protos,__ovm_bytes) end') or '',
    }
    assert((config.entry or 1) >= 1 and (config.entry or 1) % 1 == 0, 'invalid runtime entry')
    local source = template:gsub('@([A-Z]+)@', function(key)
        assert(substitutions[key], 'unknown runtime template placeholder: ' .. key)
        return substitutions[key]
    end)
    return source, {transport=transportKind, encodedBytes=encodedBytes, handlerLeaves=#entries, opcodeAliases=aliasLeaves, alphabetSeed=alphabetSeed,handlerVariants=variants,
        nativeHelpers=#native.helpers,
        cooperative=scheduling.enabled,
        guards={antiTamper=config.antiTamper==true,antiHooks=config.antiHooks or 'off',debugGuards=config.debugGuards==true}},native:source()
end

runtime.opcodes = {}
for name in pairs(handlers) do runtime.opcodes[#runtime.opcodes + 1] = name end
table.sort(runtime.opcodes)

return runtime
