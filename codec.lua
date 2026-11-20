-- Portable Lua LZSS transport. Compression is applied before payload encoding.
local M = {}
local function u32(n)
    local a=n%256; n=math.floor(n/256)
    local b=n%256; n=math.floor(n/256)
    local c=n%256; n=math.floor(n/256)
    return string.char(a,b,c,n%256)
end

function M.compress(source)
    assert(type(source)=='string','compression source must be a string')
    local output={'VLZ1',u32(#source)}
    local heads,previous={},{}
    local position,length=1,#source
    local function insert(at)
        if at+3<=length then
            local key=source:sub(at,at+3)
            previous[at]=heads[key]
            heads[key]=at
        end
    end
    while position<=length do
        local flags,tokens=0,{}
        for bit=0,7 do
            if position>length then break end
            local bestLength,bestDistance=0,0
            if position+3<=length then
                local candidate=heads[source:sub(position,position+3)]
                local maximum=math.min(259,length-position+1)
                local attempts=0
                while candidate and position-candidate<=65535 and attempts<24 do
                    local matched=4
                    while matched<maximum and source:byte(candidate+matched)==source:byte(position+matched) do
                        matched=matched+1
                    end
                    if matched>bestLength then
                        bestLength,bestDistance=matched,position-candidate
                        if matched==maximum then break end
                    end
                    candidate=previous[candidate]; attempts=attempts+1
                end
            end
            if bestLength>=4 then
                flags=flags+2^bit
                tokens[#tokens+1]=string.char(bestDistance%256,math.floor(bestDistance/256),bestLength-4)
                for at=position,position+bestLength-1 do insert(at) end
                position=position+bestLength
            else
                tokens[#tokens+1]=source:sub(position,position)
                insert(position); position=position+1
            end
        end
        output[#output+1]=string.char(flags)
        output[#output+1]=table.concat(tokens)
    end
    return table.concat(output)
end

function M.decompress(source)
    assert(type(source)=='string' and source:sub(1,4)=='VLZ1' and #source>=8,'invalid compressed header')
    local a,b,c,d=source:byte(5,8)
    local length=a+b*256+c*65536+d*16777216
    -- Invalid input must not allocate solely from an untrusted advertised size.
    assert(length<=(#source-8)*259,'invalid compressed size')
    local bytes,at,produced={},9,0
    while produced<length do
        local control=source:byte(at); at=at+1
        assert(control,'truncated compressed control')
        for bit=0,7 do
            if produced>=length then break end
            if math.floor(control/2^bit)%2==0 then
                local value=source:sub(at,at)
                assert(#value==1,'truncated compressed literal')
                at=at+1; produced=produced+1; bytes[produced]=value
            else
                local lo,hi,count=source:byte(at,at+2)
                assert(count,'truncated compressed match')
                at=at+3
                local distance=lo+hi*256; count=count+4
                assert(distance>0 and distance<=produced and count<=length-produced,'invalid compressed match')
                for i=1,count do
                    produced=produced+1; bytes[produced]=bytes[produced-distance]
                end
            end
        end
    end
    assert(at==#source+1,'unexpected compressed suffix')
    return table.concat(bytes)
end

return M
