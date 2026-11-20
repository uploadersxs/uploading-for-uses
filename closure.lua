-- Construct wrappers for virtual functions using native Luau. Captures remain
-- references to the same VM cells, and the function body still runs in the VM.
local M={}

local source=[=[
local function __ovm_makeclosure(__ovm_p,__ovm_l,__ovm_u,__ovm_childindex,__ovm_env,__ovm_runfn)
    local __ovm_child=__ovm_protos[__ovm_p.children[__ovm_childindex]]
    local __ovm_capture={}
    for __ovm_i,__ovm_uv in __ovm_ipairs(__ovm_child.upvalues) do
        if __ovm_uv.kind==1 then __ovm_capture[__ovm_i]=__ovm_l[__ovm_uv.index]
        else __ovm_capture[__ovm_i]=__ovm_u[__ovm_uv.index] end
    end
    local __ovm_closure
    __ovm_closure=function(...)
        return __ovm_runfn(__ovm_child,__ovm_capture,__ovm_pack(...),__ovm_getfenv(__ovm_closure))
    end
    __ovm_setfenv(__ovm_closure,__ovm_env)
    return __ovm_closure
end
]=]

function M.render(config,native)
    if not config or config.nativeHelpers~=true or not native or not native.enabled then return '' end
    return native:lift(source,'__ovm_makeclosure',
        {'__ovm_protos','__ovm_ipairs','__ovm_pack','__ovm_getfenv','__ovm_setfenv'})
end

return M
