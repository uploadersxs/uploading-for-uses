-- One operand contract shared by verification, optimization and wire encoding.
local M = {specs={}, names={}}
local letters={'a','b','c','d'}
local function spec(name,count,reads,writes,extra)
    local s=extra or {}; s.fields={}; s.reads=reads or {}; s.writes=writes or {}
    for i=1,count do s.fields[i]=letters[i] end
    s.slotReads=s.slotReads or {}; s.slotWrites=s.slotWrites or {}
    s.constant=s.constant or {}; s.child=s.child or {}; s.upvalue=s.upvalue or {}
    M.specs[name]=s; M.names[#M.names+1]=name
end
spec('LOADK',2,{}, {1},{constant={2}})
spec('MOVE',2,{2},{1})
spec('GETLOCAL',2,{}, {1},{slotReads={2}})
spec('NEWLOCAL',2,{2},{},{slotWrites={1}})
spec('SETLOCAL',2,{2},{},{slotWrites={1}})
spec('GETLOCAL1',2,{}, {1},{slotReads={2}})
spec('NEWLOCAL1',2,{2},{},{slotWrites={1}})
spec('SETLOCAL1',2,{2},{},{slotWrites={1}})
spec('LOADLOCAL',2,{},{},{slotWrites={1},constant={2}})
spec('LOADLOCALC',2,{},{},{slotWrites={1},constant={2}})
spec('GETUP',2,{}, {1},{upvalue={2}})
spec('SETUP',2,{2},{},{upvalue={1}})
spec('GETGLOBAL',2,{}, {1},{constant={2}})
spec('SETGLOBAL',2,{2},{},{constant={1}})
spec('GETTABLE',3,{2,3},{1})
spec('GETMETHOD',3,{2,3},{1})
spec('SETTABLE',3,{1,2,3},{})
spec('NEWTABLE',2,{}, {1})
spec('BIN',4,{2,3},{1})
spec('UN',3,{2},{1})
spec('JMP',1,{},{},{branch=1,unconditional=true})
spec('JMPIF',3,{1},{},{branch=2})
spec('PACK',1,{}, {1})
spec('PUSH',2,{1,2},{})
spec('EXTEND',2,{1,2},{})
spec('PICK',3,{2},{1})
spec('CALL',3,{2,3},{1})
spec('CALL1',3,{2,3},{1})
spec('CALL0',2,{1,2},{})
spec('CALLF0',3,{1},{},{range={first=2,count=3}})
spec('CALLF1',4,{2},{1},{range={first=3,count=4}})
spec('CALLFN',4,{2},{1},{range={first=3,count=4}})
for results=2,6 do
    spec('CALLF'..results,4,{2},{1},{range={first=3,count=4},writeRange={first=1,size=results}})
end
spec('GUARDTUPLE',3,{1},{},{range={first=2,count=3},guardTuple=true})
spec('RETURN',1,{1},{},{terminal=true})
spec('RETURN1',1,{1},{},{terminal=true})
spec('RETURN0',0,{},{},{terminal=true})
spec('VARARG',1,{}, {1})
spec('CLOSURE',2,{}, {1},{child={2}})
spec('SETLIST',3,{1,3},{})
spec('NOP',4,{},{})
spec('OPAQUE',4,{},{},{branch=2,unconditional=true})
M.specs.OPAQUE.fields={'b','c','d'} -- The reserved a operand carries no value.
spec('ITERPREP',2,{2},{1})
spec('FORPREP',3,{1,2,3},{1,2,3})
spec('TOSTRING',2,{2},{1})
M.positions={a=1,b=2,c=3,d=4}
function M.used(root)
    local used={}
    local function visit(p)
        for _,ins in ipairs(p.code) do used[ins.op]=true end
        for _,child in ipairs(p.children) do visit(child) end
    end
    visit(root); return used
end
return M
