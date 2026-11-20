-- Bind the verified instruction stream once per VM frame. Block selection,
-- cache lookups and exact-byte checks execute together in native Luau.
local M={}

function M.render(config,native)
    assert(type(config)=='table','instruction fetch config must be a table')
    local result={helpers='',frame='',fetch='',enabled=config.antiTamper==true}
    if not result.enabled then return result end

    local lazy=config.lazyInstructions==true
    local setup,site
    if lazy then
        local cache=config.instructionCache or 'prototype'
        assert(cache=='prototype' or cache=='execution' or cache=='none','invalid instruction cache')
        setup='    local __ovm_blocksize=__ovm_p.blockSize\n'
            ..'    local __ovm_blockcache='..(cache=='prototype' and '__ovm_instructioncaches[__ovm_p.id]' or cache=='execution' and '{}' or 'nil')..'\n'
        if cache=='prototype' then
            setup=setup..'    if not __ovm_blockcache then\n'
                ..'        __ovm_blockcache={}\n'
                ..'        __ovm_instructioncaches[__ovm_p.id]=__ovm_blockcache\n'
                ..'    end\n'
        end
        setup=setup..'    local __ovm_activeblock,__ovm_blockentry\n'
        site=[=[
        local __ovm_blockindex=__ovm_floor((__ovm_pc-1)/__ovm_blocksize)+1
        if __ovm_activeblock~=__ovm_blockindex then
            __ovm_blockentry=__ovm_blockcache and __ovm_blockcache[__ovm_blockindex]
            if not __ovm_blockentry then
                __ovm_blockentry=__ovm_materializeblock(__ovm_p,__ovm_blockindex,__ovm_blockcache)
            end
            __ovm_activeblock=__ovm_blockindex
        end
        local __ovm_index=__ovm_pc-(__ovm_blockindex-1)*__ovm_blocksize
        local __ovm_at=__ovm_blockentry.sites[__ovm_index]
        local __ovm_record=__ovm_blockentry.checks[__ovm_index]
        local __ovm_op,__ovm_a,__ovm_b,__ovm_c,__ovm_d=__ovm_checkedinstruction(__ovm_blockentry.data,__ovm_at,__ovm_record)
]=]
    else
        setup='    local __ovm_checks=__ovm_p.checks\n'
            ..(config.compact and '    local __ovm_sites=__ovm_p.sites\n' or '    local __ovm_base=__ovm_p.offset\n')
        site='        local __ovm_at='..(config.compact and '__ovm_sites[__ovm_pc]' or '__ovm_base+(__ovm_pc-1)*17')..'\n'
            ..'        local __ovm_record=__ovm_checks[__ovm_pc]\n'
            ..'        local __ovm_op,__ovm_a,__ovm_b,__ovm_c,__ovm_d=__ovm_checkedinstruction(__ovm_bytes,__ovm_at,__ovm_record)\n'
    end

    result.helpers=[=[
local function __ovm_instructionframe(__ovm_p)
    local __ovm_count=__ovm_p.count
]=]..setup..[=[
    return function(__ovm_pc)
        if __ovm_type(__ovm_pc)~='number' or __ovm_pc<1 or __ovm_pc>__ovm_count or __ovm_pc%1~=0 then
            __ovm_error('',0)
        end
]=]..site..[=[
        return __ovm_op,__ovm_a,__ovm_b,__ovm_c,__ovm_d,__ovm_record
    end
end
]=]
    if config.nativeHelpers and native then
        local captures={'__ovm_bytes','__ovm_buffer','__ovm_floor','__ovm_error','__ovm_type',
            '__ovm_instructioncaches','__ovm_materializeblock','__ovm_checkedinstruction'}
        local values={lazy and 'nil' or '__ovm_bytes','__ovm_buffer','__ovm_floor','__ovm_error','__ovm_type',
            lazy and (config.instructionCache==nil or config.instructionCache=='prototype') and '__ovm_instructioncaches' or 'nil',
            lazy and '__ovm_materializeblock' or 'nil','__ovm_checkedinstruction'}
        result.helpers=native:lift(result.helpers,'__ovm_instructionframe',captures,values)
    end
    result.frame='local __ovm_fetch=__ovm_instructionframe(__ovm_p)'
    result.fetch='local __ovm_op,__ovm_a,__ovm_b,__ovm_c,__ovm_d,__ovm_expected=__ovm_fetch(__ovm_pc)'
    return result
end

return M
