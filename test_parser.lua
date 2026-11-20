package.path = './?.lua;' .. package.path
local lexer = require('src.lexer')
local parser = require('src.parser')
local util = require('src.util')

local invalid = {
    'local x=0x_', 'local x=0X___', 'local x=0b_', 'local x=0B___',
    'local x=0b102', 'local x=0xg', 'local x=1e_', 'local x=1e+',
    'return; print(1)', 'return;;', 'do return; local x=1 end',
    'while false do break; print(1) end', 'while false do break;; end',
    'while false do continue; print(1) end',
}
for _, source in ipairs(invalid) do
    local ok, err = pcall(parser.parse, source, 'invalid.luau')
    assert(not ok, 'parser accepted invalid Luau: ' .. source)
    assert(tostring(err):find('invalid.luau:1:', 1, true), 'missing source location')
end

local valid = {
    'local x=0x__f; local y=0b__1; local z=1._',
    'local x=.5e+2; local y=1_2.3_4e-0_2',
    'do return; end', 'while false do break; end',
    'while false do continue; end',
    'local continue=function() end; continue(); local x=1',
    'local text=`a{`b{1+2}`}c`',
}
for _, source in ipairs(valid) do parser.parse(source, 'valid.luau') end

local tokens = lexer.lex('local a=1\r\n  local b=2\r local c=3', 'lines.luau')
assert(tokens[1].line == 1 and tokens[1].column == 1)
assert(tokens[5].line == 2 and tokens[5].column == 3)
assert(tokens[9].line == 3 and tokens[9].column == 2)
local ok, err = pcall(parser.parse, 'local a=1\n  local =2', 'columns.luau')
assert(not ok and tostring(err):find('columns.luau:2:9:', 1, true), 'parser column incorrect')

for _, name in ipairs({'core', 'loops', 'luau', 'runtime', 'evaluation', 'numbers',
    'advanced', 'interpolation', 'types', 'minify', 'optimizer', 'lazy'}) do
    parser.parse(util.read('tests/fixtures/' .. name .. '.luau'), name .. '.luau')
end
print('Parser checks OK')
