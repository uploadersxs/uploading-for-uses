-- Lift only trusted runtime helpers. The dispatcher still controls execution;
-- these closures retain the loader, cache and exact-integrity contracts.
local M={}

function M.apply(native,config,safeLoader,instructionVM,constantHelper)
    if not native.enabled then return constantHelper end
    local function lift(source,name,captures)
        local values={}
        for index,capture in ipairs(captures) do
            values[index]=capture
            if capture=='__ovm_guardfreezeentry' and not config.antiTamper then values[index]='nil' end
            if (capture=='__ovm_fieldkeys' or capture=='__ovm_fieldstrides')
                and not (config.operandKeys or config.operandStrides) then values[index]='nil' end
        end
        return native:lift(source,name,captures,values)
    end

    safeLoader.helpers=native:lift(safeLoader.helpers,'__ovm_limit',
        {'__ovm_error','__ovm_type','__ovm_floor'})
    safeLoader.validate=native:lift(safeLoader.validate,'__ovm_validateinstruction',
        {'__ovm_limit','__ovm_buffer','__ovm_loaderschema','__ovm_limits','__ovm_type','__ovm_error'})

    instructionVM.decode=native:lift(instructionVM.decode,'__ovm_decodeopcode',
        {'__ovm_error'})
    instructionVM.decode=lift(instructionVM.decode,'__ovm_decodeinstruction',
        {'__ovm_error','__ovm_buffer','__ovm_bit','__ovm_instrsizes','__ovm_instrorders',
            '__ovm_validateinstruction','__ovm_decodeopcode','__ovm_instructionoffsets',
            '__ovm_fieldkeys','__ovm_fieldstrides'})

    if config.lazyInstructions then
        instructionVM.helpers=lift(instructionVM.helpers,'__ovm_materializeblock',
            {'__ovm_instructioncaches','__ovm_limit','__ovm_limits','__ovm_length','__ovm_bytes',
                '__ovm_buffer','__ovm_floor','__ovm_blockkey','__ovm_blockdigest',
                '__ovm_decodeinstruction','__ovm_guardfreezeentry','__ovm_entryenv',
                '__ovm_accelerators','__ovm_type','__ovm_error'})
    end

    local captures={'__ovm_bytes','__ovm_length','__ovm_buffer','__ovm_floor','__ovm_error',
        '__ovm_tonumber','__ovm_limit','__ovm_guardfreezeentry','__ovm_entryenv',
        '__ovm_accelerators','__ovm_type','__ovm_limits'}
    if (config.version or 1)==1 then
        -- Version 1 emits a one-line lookup function and has no lazy pool.
        -- Using the complete declaration also avoids changing lift's balanced
        -- multiline-function matching rule for the more complex helpers.
        return native:block(constantHelper,{},nil,{'__ovm_constant'})
    end
    return lift(constantHelper,'__ovm_constant',captures)
end

return M
