-- Accelerate trusted generator byte-work only. User code never enters this
-- module; payloads, keys and captured dependencies are passed by the packed VM.
local M={}

function M.new(enabled,cooperative)
    local self={enabled=enabled==true,helpers={},cooperative=cooperative==true}
    function self:block(body,parameters,values,outputs,declare,boundInside)
        if not self.enabled then return body end
        parameters=parameters or {}; values=values or parameters; outputs=outputs or {}
        assert(#parameters==#values,'native helper argument mismatch')
        if self.cooperative and body:find(' do\n',1,true) then
            if not boundInside then body='local __ovm_nativecheckpoint=__ovm_nativebindcheckpoint()\n'..body end
            body=body:gsub(' do\n',' do\n__ovm_nativecheckpoint()\n')
        end
        self.helpers[#self.helpers+1]='function('..table.concat(parameters,',')..')\n'..body
            ..(#outputs>0 and '\nreturn '..table.concat(outputs,',') or '')..'\nend'
        local call='__ovm_accelerators['..#self.helpers..']('..table.concat(values,',')..')'
        return (#outputs>0 and ((declare==false and '' or 'local ')..table.concat(outputs,',')..'=') or '')..call
    end
    function self:lift(source,name,captures,values)
        if not self.enabled then return source end
        local first,last=source:find('local function '..name..'%b().-\nend')
        assert(first,'missing trusted native function '..name)
        local body=source:sub(first,last)
        if self.cooperative and body:find(' do\n',1,true) then
            body=body:gsub('(local function '..name..'%b()[^\n]*\n)','%1local __ovm_nativecheckpoint=__ovm_nativebindcheckpoint()\n',1)
        end
        local replacement=self:block(body,captures,values,{name},nil,true)
        return source:sub(1,first-1)..replacement..source:sub(last+1)
    end
    function self:source()
        return '{'..table.concat(self.helpers,',\n')..'}'
    end
    return self
end

return M
