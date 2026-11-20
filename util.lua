local M = {}
local modulus = 2147483647

function M.rng(seed)
    local state = seed
    local random = {}
    function random:int(lo, hi)
        state = (state * 48271) % modulus
        return lo + state % (hi - lo + 1)
    end
    function random:chance(p)
        return self:int(0, 1000000) / 1000000 < p
    end
    function random:shuffle(items)
        for i = #items, 2, -1 do
            local j = self:int(1, i)
            items[i], items[j] = items[j], items[i]
        end
        return items
    end
    return random
end

function M.seed(value)
    local seed = tonumber(value)
    assert(seed and seed == math.floor(seed) and seed >= 1 and seed < modulus,
        'seed must be an integer between 1 and 2147483646')
    return seed
end

function M.read(path)
    local file, err = io.open(path, 'rb')
    if not file then error(err, 0) end
    local data = file:read('*a')
    file:close()
    return data
end

local taskCwd
function M.absolute(path)
    assert(type(path)=='string' and not path:find('\0',1,true), 'invalid file path')
    local windows = package.config:sub(1,1)=='\\'
    if not taskCwd then
        local pipe=assert(io.popen(windows and 'cd' or 'pwd'), 'cannot determine current directory')
        taskCwd=pipe:read('*l')
        pipe:close()
        assert(taskCwd and #taskCwd>0, 'cannot determine current directory')
        taskCwd=taskCwd:gsub('\\','/')
    end
    if windows then path=path:gsub('\\','/') end
    if windows and path:match('^%a:') and not path:match('^%a:/') then
        error('drive-relative paths are unsupported; use an absolute path',0)
    end
    if windows and path:sub(1,1)=='/' and path:sub(1,2)~='//' then
        path=taskCwd:sub(1,2)..path
    elseif path:sub(1,1)~='/' and not path:match('^%a:/') then
        path=taskCwd..'/'..path
    end
    local root,tail
    if path:sub(1,2)=='//' then
        root,tail=path:match('^(//[^/]+/[^/]+)(.*)$')
        assert(root, 'invalid UNC file path')
        root=root..'/'
    elseif path:match('^%a:/') then root,tail=path:sub(1,3),path:sub(4)
    else root,tail='/',path:sub(2) end
    local segments={}
    for part in tail:gmatch('[^/]+') do
        if part=='..' then segments[#segments]=nil
        elseif part~='.' then
            if windows then part=part:gsub('[ %.]+$','') end
            assert(#part>0, 'invalid empty path component')
            segments[#segments+1]=part
        end
    end
    local result=root..table.concat(segments,'/')
    return windows and result:lower() or result
end

function M.write(path, data)
    local file, err = io.open(path, 'wb')
    if not file then error(err, 0) end
    local ok, failure = file:write(data)
    local closed,closeFailure=file:close()
    if not ok then error(failure, 0) end
    if not closed then error(closeFailure,0) end
end

function M.exists(path)
    local file=io.open(path,'rb')
    if not file then return false end
    file:close()
    return true
end

-- ASCII command transport keeps user paths out of the command shell.
local base64Alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
function M.base64(value)
    local out={}
    for i=1,#value,3 do
        local a,b,c=value:byte(i,i+2)
        local n=a*65536+(b or 0)*256+(c or 0)
        local indices={math.floor(n/262144)%64,math.floor(n/4096)%64,math.floor(n/64)%64,n%64}
        out[#out+1]=base64Alphabet:sub(indices[1]+1,indices[1]+1)..base64Alphabet:sub(indices[2]+1,indices[2]+1)
            ..(b and base64Alphabet:sub(indices[3]+1,indices[3]+1) or '=')
            ..(c and base64Alphabet:sub(indices[4]+1,indices[4]+1) or '=')
    end
    return table.concat(out)
end

function M.unbase64(value)
    local digits={}
    for i=1,#base64Alphabet do digits[base64Alphabet:sub(i,i)]=i-1 end
    local out={}
    assert(#value%4==0,'invalid base64 length')
    for i=1,#value,4 do
        local a,b,c,d=value:sub(i,i),value:sub(i+1,i+1),value:sub(i+2,i+2),value:sub(i+3,i+3)
        assert(digits[a] and digits[b] and (digits[c] or c=='=') and (digits[d] or d=='='),'invalid base64')
        local n=digits[a]*262144+digits[b]*4096+(digits[c] or 0)*64+(digits[d] or 0)
        out[#out+1]=string.char(math.floor(n/65536)%256)
        if c~='=' then out[#out+1]=string.char(math.floor(n/256)%256) end
        if d~='=' then out[#out+1]=string.char(n%256) end
    end
    return table.concat(out)
end

local function psPath(value)
    return "[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('"..M.base64(value).."'))"
end

local function powershell(script)
    local wrapped="$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; try { "..script
        .." } catch { [Console]::WriteLine('ERR:'+ [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.Exception.Message))); exit 1 }"
    local utf16=wrapped:gsub('.',function(ch) return ch..'\0' end)
    local pipe=assert(io.popen('powershell.exe -NoProfile -NonInteractive -EncodedCommand '..M.base64(utf16),'r'),
        'cannot start PowerShell')
    local result=pipe:read('*a') or ''
    pipe:close()
    local failure=result:match('ERR:([A-Za-z0-9+/=]+)')
    if failure then error(M.unbase64(failure),0) end
    return result
end

local function shellQuote(value)
    assert(not value:find('\0',1,true),'invalid shell path')
    return "'"..value:gsub("'","'\\''").."'"
end

local createdDirectories={}
function M.mkdir(path)
    local absolute=M.absolute(path)
    if createdDirectories[absolute] then return end
    if package.config:sub(1,1)=='\\' then
        local result=powershell('$taskPath='..psPath(absolute).."; [IO.Directory]::CreateDirectory($taskPath) | Out-Null; [Console]::WriteLine('OK')")
        assert(result:match('OK'), 'cannot create output directory')
    else
        local pipe=assert(io.popen('mkdir -p -- '..shellQuote(path).." && printf 'OK'",'r'))
        local result=pipe:read('*a'); pipe:close()
        assert(result=='OK','cannot create output directory: '..path)
    end
    createdDirectories[absolute]=true
end

function M.listSources(path)
    local files={}
    if package.config:sub(1,1)=='\\' then
        local result=powershell('$taskPath='..psPath(M.absolute(path)).."; if (-not [IO.Directory]::Exists($taskPath)) { throw 'batch directory does not exist' }; "
            .."Get-ChildItem -LiteralPath $taskPath -Recurse -File | Where-Object { $_.Extension -in '.lua','.luau' } | Sort-Object FullName | "
            .."ForEach-Object { [Console]::WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.FullName))) }; [Console]::WriteLine('DONE')")
        assert(result:match('DONE%s*$'),'directory enumeration failed')
        for line in result:gmatch('[^\r\n]+') do if line~='DONE' then files[#files+1]=M.unbase64(line) end end
    else
        local command='find '..shellQuote(M.absolute(path)).." -type f \\( -iname '*.lua' -o -iname '*.luau' \\) -print0 && printf 'VERITY_DONE'"
        local pipe=assert(io.popen(command,'r'),'cannot enumerate batch directory')
        local result=pipe:read('*a') or ''; pipe:close()
        assert(result:sub(-11)=='VERITY_DONE','directory enumeration failed: '..path)
        result=result:sub(1,-12)
        for file in result:gmatch('([^%z]+)%z') do files[#files+1]=file end
    end
    table.sort(files)
    return files
end

local temporaryCounter=0
function M.atomicWrite(path,data,overwrite)
    assert(type(path)=='string' and not path:find('\0',1,true),'invalid output path')
    if not overwrite and M.exists(path) then error('output already exists; choose another name or use --force',0) end
    local temporary
    repeat
        temporaryCounter=temporaryCounter+1
        temporary=path..'.verity-'..tostring(os.time())..'-'..tostring(math.floor(os.clock()*1000000))..'-'..temporaryCounter..'.tmp'
    until not M.exists(temporary)
    local ok,failure=pcall(function()
        M.write(temporary,data)
        if package.config:sub(1,1)=='\\' then
            -- Native rename is enough for a new destination; File.Replace handles existing files.
            local moved=os.rename(temporary,path)
            if moved then return end
            local result=powershell('$taskSource='..psPath(M.absolute(temporary))..'; $taskTarget='..psPath(M.absolute(path))..'; $taskBackup='..psPath(M.absolute(temporary..'.backup'))..'; '
                ..'if ([IO.File]::Exists($taskTarget)) { '
                ..(overwrite and '[IO.File]::Replace($taskSource,$taskTarget,$taskBackup); try { [IO.File]::Delete($taskBackup) } catch {}' or "throw 'output already exists; choose another name or use --force'")
                .." } else { [IO.File]::Move($taskSource,$taskTarget) }; [Console]::WriteLine('OK')")
            assert(result:match('OK'),'cannot commit output file')
        else
            if not overwrite and M.exists(path) then error('output already exists; choose another name or use --force',0) end
            local moved,err=os.rename(temporary,path)
            if not moved then error(err,0) end
        end
    end)
    if not ok then os.remove(temporary); error(failure,0) end
end

local function jsonString(value)
    local escapes={['"']='\\"',['\\']='\\\\',['\b']='\\b',['\f']='\\f',['\n']='\\n',['\r']='\\r',['\t']='\\t'}
    return '"'..value:gsub('[%z\1-\31\\"]',function(ch) return escapes[ch] or string.format('\\u%04x',ch:byte()) end)..'"'
end

function M.json(value)
    local active={}
    local function encode(item)
        local kind=type(item)
        if kind=='nil' then return 'null'
        elseif kind=='boolean' then return item and 'true' or 'false'
        elseif kind=='string' then return jsonString(item)
        elseif kind=='number' then
            assert(item==item and item~=math.huge and item~=-math.huge,'JSON cannot encode a non-finite number')
            local text=string.format('%.17g',item)
            local separator=string.format('%.1f',0.5):match('^0(.-)5$')
            if separator and separator~='.' then
                local first,last=text:find(separator,1,true)
                if first then text=text:sub(1,first-1)..'.'..text:sub(last+1) end
            end
            return text
        end
        assert(kind=='table','unsupported JSON value: '..kind)
        assert(not active[item],'cyclic JSON table'); active[item]=true
        local count,maximum,array=0,0,true
        for key in pairs(item) do
            count=count+1
            if type(key)~='number' or key<1 or key%1~=0 then array=false
            elseif key>maximum then maximum=key end
        end
        array=array and count>0 and maximum==count
        local parts={}
        if array then
            for i=1,count do parts[i]=encode(item[i]) end
        else
            local keys={}
            for key in pairs(item) do assert(type(key)=='string' or type(key)=='number','invalid JSON object key'); keys[#keys+1]=key end
            table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
            for _,key in ipairs(keys) do parts[#parts+1]=jsonString(tostring(key))..':'..encode(item[key]) end
        end
        active[item]=nil
        return (array and '[' or '{')..table.concat(parts,',')..(array and ']' or '}')
    end
    return encode(value)
end

return M
