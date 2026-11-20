-- Feedback transport scrambler; deliberately not a cryptographic API.
local M={}
local floor=math.floor
local modulus=2147483647

function M.crypt(source,config,decrypt)
    assert(type(source)=='string','cipher input must be a string')
    assert(type(config)=='table','cipher config required')
    local state,multiplier=config.key,config.multiplier
    assert(type(state)=='number' and state>=1 and state<modulus and state%1==0,'invalid cipher key')
    assert(type(multiplier)=='number' and multiplier>=10001 and multiplier<=100000 and multiplier%1==0,'invalid cipher multiplier')
    local out={}
    for i=1,#source do
        state=(state*multiplier)%modulus
        local mask=floor(state/65536)%256
        local value=source:byte(i)
        local plain
        if decrypt then
            plain=(value-mask)%256
            out[i]=string.char(plain)
        else
            plain=value
            out[i]=string.char((plain+mask)%256)
        end
        state=(state+plain+(i-1)%251)%modulus
        if state==0 then state=1 end
    end
    return table.concat(out)
end

return M
