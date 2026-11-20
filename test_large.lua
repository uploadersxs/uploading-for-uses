package.path='./?.lua;'..package.path
local obfuscator=require('src.obfuscator')
local util=require('src.util')
local source=util.read('spintoupgrade.lua')
local template=util.read('tests/fixtures/spin_mock.luau')
assert(#source>80000,'large-script regression must exercise the real Spin input')
local function harness(code, cooperative)
    local output,count=template:gsub('%-%-@SPIN_SOURCE@',function() return code end,1)
    assert(count==1,'missing Spin mock source marker')
    if cooperative then
        output,count=output:gsub('%-%-@SPIN_EXPECT_COOPERATIVE@',
            'assert(entryCheckpoints>0,"Cooperative startup did not yield")',1)
        assert(count==1,'missing Spin cooperative marker')
    end
    output,count=output:gsub('%-%-@SPIN_REPORT@','print("spin checkpoints "..entryCheckpoints)',1)
    assert(count==1,'missing Spin report marker')
    return output
end
util.write('tests/.generated/spin_large_native_mock.luau',harness(source,false))
for _,variant in ipairs({'max','cooperative'}) do
    local options={profile='max',seed=12345,chunkname='spintoupgrade.lua'}
    if variant=='cooperative' then
        options.cooperative=true
        options.yieldBudgetMs=1
        options.yieldInterval=64
    end
    local code,stats=obfuscator.obfuscate(source,options)
    assert(stats.mainPacked and stats.main.layers==2,'large max must retain both VM layers')
    assert(stats.wireVersion==3 and stats.main.wireVersion==3,'large max must retain protected v3 blocks')
    assert(stats.guards.antiTamper and stats.main.guards.antiTamper,'large max must retain both integrity layers')
    assert(stats.settings.lazyInstructions and stats.settings.perPrototypeOpcodes,
        'large max must retain lazy instructions and per-prototype opcode maps')
    assert(stats.settings.nativeHelpers==true,'max must enable native runtime helpers by default')
    assert(stats.settings.cooperative==true,'large max must enable cooperative startup by default')
    local path='tests/.generated/spin_large_'..variant
    util.write(path..'.luau',code)
    util.write(path..'_mock.luau',harness(code,true))
    util.write(path..'_stats.json',util.json(stats)..'\n')
end
print('Large script generation OK')
