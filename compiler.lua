-- Register bytecode compiler. Captured locals retain mutable cells.
local M = {}
local C = {}
C.__index = C

local binary = {['+']=1,['-']=2,['*']=3,['/']=4,['//']=5,['%']=6,['^']=7,
    ['..']=8,['==']=9,['~=']=10,['<']=11,['<=']=12,['>']=13,['>=']=14}
local unary = {['-']=1,['not']=2,['#']=3}

local function fail(self, node, message)
    error(('%s:%s:%s: %s'):format(self.options.chunkname or self.proto.chunkname,
        node and node.line or '?',node and node.column or 1,message),0)
end

function C.new(parent, vararg, options)
    options = options or (parent and parent.options) or {}
    return setmetatable({parent=parent, scopes={{}}, loops={}, constantMap={}, upvalueMap={},
        options=options,
        proto={code={},constants={},children={},upvalues={},params={},vararg=vararg,
            slots=0,registers=0,boxed={},lines={},chunkname=options.chunkname or '<input>'}}, C)
end

function C:emit(op,a,b,c,d)
    local code = self.proto.code
    code[#code+1] = {op=op,a or 0,b or 0,c or 0,d or 0,line=self.currentLine or 1}
    self.proto.lines[#code] = self.currentLine or 1
    return #code
end

function C:pc() return #self.proto.code+1 end
function C:patch(pc, target)
    local ins = self.proto.code[pc]
    if ins.op == 'JMP' then ins[1] = target else ins[2] = target end
end
function C:reg()
    self.proto.registers = self.proto.registers+1
    return self.proto.registers
end
function C:pushScope() self.scopes[#self.scopes+1]={} end
function C:popScope() self.scopes[#self.scopes]=nil end

function C:declare(name,readonly)
    self.proto.slots=self.proto.slots+1
    local binding={kind='local',index=self.proto.slots,readonly=readonly or false}
    self.scopes[#self.scopes][name]=binding
    return binding.index
end

function C:resolve(name)
    for i=#self.scopes,1,-1 do
        local binding=self.scopes[i][name]
        if binding then
            if self.conditionReads then self.conditionReads[binding.index]=true end
            return binding
        end
    end
    if self.parent then
        local binding=self.parent:resolve(name)
        if binding.kind~='global' then
            if binding.kind=='local' then self.parent.proto.boxed[binding.index]=true end
            local key=binding.kind..':'..binding.index
            local id=self.upvalueMap[key]
            if not id then
                id=#self.proto.upvalues+1
                self.proto.upvalues[id]={kind=binding.kind,index=binding.index}
                self.upvalueMap[key]=id
            end
            return {kind='upvalue',index=id,readonly=binding.readonly}
        end
    end
    return {kind='global',name=name}
end

function C:constant(kind,value)
    local key=kind..':'..tostring(value)
    -- String and number keys include their type. NaNs deliberately are not shared.
    if kind=='number' then key=kind..':'..string.format('%.17g',value) end
    local id=self.constantMap[key]
    if not id then
        id=#self.proto.constants+1
        self.proto.constants[id]={kind=kind,value=value}
        self.constantMap[key]=id
    end
    return id
end

function C:literal(kind,value)
    local r=self:reg()
    self:emit('LOADK',r,self:constant(kind,value))
    return r
end

-- The generated dispatcher masks integers as (value + salt - salt). When that
-- runtime is packed into another VM, keep the mask in its encrypted constant
-- pool instead of interpreting two loads and a subtraction on every visit.
-- User expressions, nonintegral values and computed operands never qualify.
function C:runtimeNumber(node)
    if self.options.trustedRuntime~=true or not node or node.tag~='Binary' or node.op~='-' then return end
    local left,right=node.left,node.right
    if not left or not right or left.tag~='Number' or right.tag~='Number' then return end
    local a,b=left.value,right.value
    local ceiling=4294967296+16383
    if type(a)~='number' or type(b)~='number' or a<0 or b<0 or a>ceiling or b>ceiling
        or a%1~=0 or b%1~=0 or a<b or a-b>4294967296 then return end
    -- A negative zero can only enter a Number through a caller-built AST; Luau
    -- source represents it as Unary. Preserve its sign in either case.
    if (a==0 and 1/a<0) or (b==0 and 1/b<0) then return end
    return a-b
end

function C:read(binding)
    local r=self:reg()
    if binding.kind=='local' then self:emit('GETLOCAL',r,binding.index)
    elseif binding.kind=='upvalue' then self:emit('GETUP',r,binding.index)
    else self:emit('GETGLOBAL',r,self:constant('string',binding.name)) end
    return r
end

-- Luau borrows an own local's register for arithmetic and table operands.
-- A later expression can therefore mutate that operand before the operation.
-- Captured/global values and computed expressions use temporary snapshots.
function C:localOperand(node)
    while node and node.tag=='Paren' do node=node.value end
    if node and node.tag=='Name' then
        local binding=self:resolve(node.name)
        if binding.kind=='local' then return binding end
    end
end

function C:operand(node)
    local binding=self:localOperand(node)
    if binding then return {binding=binding} end
    return {register=self:expr(node)}
end

function C:materialize(operand)
    return operand.register or self:read(operand.binding)
end

function C:address(node)
    if node.tag=='Name' then
        local binding=self:resolve(node.name)
        if binding.readonly then fail(self,node,"cannot assign to const local '"..node.name.."'") end
        return binding
    end
    if node.tag=='Index' then
        return {kind='index',object=self:operand(node.object),key=self:operand(node.key)}
    end
    fail(self,node,'invalid assignment target '..tostring(node.tag))
end

function C:readAddress(binding)
    if binding.kind=='index' then
        local object=self:materialize(binding.object); local key=self:materialize(binding.key)
        local r=self:reg(); self:emit('GETTABLE',r,object,key); return r
    end
    return self:read(binding)
end

function C:write(binding,r)
    if binding.kind=='local' then self:emit('SETLOCAL',binding.index,r)
    elseif binding.kind=='upvalue' then self:emit('SETUP',binding.index,r)
    elseif binding.kind=='global' then self:emit('SETGLOBAL',self:constant('string',binding.name),r)
    elseif binding.kind=='index' then
        self:emit('SETTABLE',self:materialize(binding.object),self:materialize(binding.key),r)
    else error('internal invalid binding',0) end
end

local function expands(node)
    return node and (node.tag=='Call' or node.tag=='MethodCall' or node.tag=='Vararg')
end

function C:list(nodes, existing)
    local p=existing or self:reg()
    if not existing then self:emit('PACK',p) end
    for i,node in ipairs(nodes or {}) do
        if i==#nodes and expands(node) then self:emit('EXTEND',p,self:multi(node))
        else self:emit('PUSH',p,self:expr(node)) end
    end
    return p
end

-- Assignment/local initializer lists need only their requested values. Keep
-- scalar snapshots in registers instead of building and immediately unpacking
-- an aggregate table, but still evaluate every excess expression for effects.
function C:rhs(nodes,count)
    nodes=nodes or {}
    local values={}
    for i,node in ipairs(nodes) do
        if i==#nodes and expands(node) and count-i+1>1 then
            local requested=count-i+1
            local fixedCalls=self.options.fixedCalls
            if fixedCalls==nil then fixedCalls=self.options.optimize~=false end
            local fixedReturns=self.options.fixedReturns
            if fixedReturns==nil then fixedReturns=self.options.optimize~=false end
            local args=node.args or {}
            if requested<=6 and fixedCalls and fixedReturns
                and (node.tag=='Call' or node.tag=='MethodCall') and not expands(args[#args]) then
                local first=self:call(node,requested)
                for index=i,count do values[index]=first+index-i end
            else
                local packed=self:multi(node)
                for index=i,count do
                    local r=self:reg(); self:emit('PICK',r,packed,index-i+1)
                    values[index]=r
                end
            end
        else
            if i>count and (node.tag=='Call' or node.tag=='MethodCall') then
                self:call(node,'discard')
            else
                local value=self:expr(node)
                if i<=count then values[i]=value end
            end
        end
    end
    local nilreg
    for i=1,count do
        if not values[i] then
            nilreg=nilreg or self:literal('nil')
            values[i]=nilreg
        end
    end
    return values
end

function C:exprInto(node,destination)
    local previous=self.currentLine
    if node and node.line then self.currentLine=node.line end
    local tag=node and node.tag or 'Nil'
    local number=self:runtimeNumber(node)
    if number~=nil then self:emit('LOADK',destination,self:constant('number',number))
    elseif tag=='Paren' then self:exprInto(node.value,destination)
    elseif tag=='Name' then
        local binding=self:resolve(node.name)
        if binding.kind=='local' then self:emit('GETLOCAL',destination,binding.index)
        elseif binding.kind=='upvalue' then self:emit('GETUP',destination,binding.index)
        else self:emit('GETGLOBAL',destination,self:constant('string',binding.name)) end
    elseif tag=='Nil' then self:emit('LOADK',destination,self:constant('nil'))
    elseif tag=='Boolean' then self:emit('LOADK',destination,self:constant('boolean',node.value))
    elseif tag=='Number' then self:emit('LOADK',destination,self:constant('number',node.value))
    elseif tag=='String' then self:emit('LOADK',destination,self:constant('string',node.value))
    else self:emit('MOVE',destination,self:expr(node)) end
    self.currentLine=previous
    return destination
end

function C:fixedArgs(nodes, object)
    -- Snapshot directly into a preallocated argument window. Earlier values
    -- stay independent of side effects in later argument expressions.
    nodes=nodes or {}
    local count=#nodes+(object and 1 or 0)
    if count==0 then return 0,0 end
    local first=self:reg()
    for _=2,count do self:reg() end
    local offset=0
    if object then self:emit('MOVE',first,object);offset=1 end
    for index,argument in ipairs(nodes) do self:exprInto(argument,first+offset+index-1) end
    return first,count
end

function C:call(node,mode)
    local f,args,object
    local nodes=node.args or {}
    if self.options.trustedRuntime and node.tag=='Call' and node.callee.tag=='Name'
        and node.callee.name=='__ovm_guardtuple' and #nodes==6 and not expands(nodes[6]) then
        -- Only generator-owned sources opt into this reserved primitive. Each
        -- value still evaluates once, in the same order as a regular call.
        local expected=self:expr(nodes[1])
        local first=self:reg()
        for _=2,5 do self:reg() end
        for index=2,6 do self:exprInto(nodes[index],first+index-2) end
        self:emit('GUARDTUPLE',expected,first,5)
        if mode=='discard' then return end
        if mode=='all' then local pack=self:reg();self:emit('PACK',pack);return pack end
        local result=self:literal('nil')
        if type(mode)=='number' then
            for _=2,mode do local register=self:reg();self:emit('MOVE',register,result) end
        end
        return result
    end
    local fixedSetting=self.options.fixedCalls
    if fixedSetting==nil then fixedSetting=self.options.optimize~=false end
    local fixed=fixedSetting and not expands(nodes[#nodes])
    if node.tag=='Call' then
        f=self:expr(node.callee)
        if not fixed then args=self:list(nodes) end
    elseif node.tag=='MethodCall' then
        object=self:expr(node.object)
        local key=self:literal('string',node.method)
        f=self:reg(); self:emit('GETMETHOD',f,object,key)
        if not fixed then
            args=self:reg(); self:emit('PACK',args); self:emit('PUSH',args,object)
            self:list(nodes,args)
        end
    else fail(self,node,'invalid call expression '..tostring(node.tag)) end
    if fixed then
        local first,count=self:fixedArgs(nodes,object)
        if mode=='discard' then self:emit('CALLF0',f,first,count); return end
        local r=self:reg()
        if type(mode)=='number' then
            assert(mode>=2 and mode<=6 and mode==math.floor(mode),'invalid fixed result count')
            for _=2,mode do self:reg() end
            self:emit('CALLF'..mode,r,f,first,count)
        else self:emit(mode=='one' and 'CALLF1' or 'CALLFN',r,f,first,count) end
        return r
    end
    if mode=='discard' then self:emit('CALL0',f,args); return end
    local r=self:reg(); self:emit(mode=='one' and 'CALL1' or 'CALL',r,f,args); return r
end

function C:multi(node)
    if node.tag=='Vararg' then
        if not self.proto.vararg then fail(self,node,'cannot use ... outside a vararg function') end
        local r=self:reg(); self:emit('VARARG',r); return r
    elseif node.tag=='Call' or node.tag=='MethodCall' then
        return self:call(node,'all')
    end
    local p=self:reg(); self:emit('PACK',p); self:emit('PUSH',p,self:expr(node)); return p
end

function C:expr(node)
    local previous=self.currentLine
    if node and node.line then self.currentLine=node.line end
    local result=self:expression(node)
    self.currentLine=previous
    return result
end

function C:expression(node)
    if not node then return self:literal('nil') end
    local tag=node.tag
    if tag=='Nil' then return self:literal('nil')
    elseif tag=='Boolean' then return self:literal('boolean',node.value)
    elseif tag=='Number' then return self:literal('number',node.value)
    elseif tag=='String' then return self:literal('string',node.value)
    elseif tag=='Name' then return self:read(self:resolve(node.name))
    elseif tag=='Paren' then return self:expr(node.value)
    elseif tag=='Call' or tag=='MethodCall' then return self:call(node,'one')
    elseif tag=='Vararg' then
        local p=self:multi(node); local r=self:reg(); self:emit('PICK',r,p,1); return r
    elseif tag=='Unary' then
        local a=self:expr(node.value); local r=self:reg()
        if not unary[node.op] then fail(self,node,'unsupported unary operator '..tostring(node.op)) end
        self:emit('UN',r,a,unary[node.op]); return r
    elseif tag=='Binary' then
        local number=self:runtimeNumber(node)
        if number~=nil then return self:literal('number',number) end
        local r=self:reg()
        if node.op=='and' or node.op=='or' then
            local a=self:expr(node.left)
            self:emit('MOVE',r,a)
            local jump=self:emit('JMPIF',r,0,node.op=='or' and 1 or 0)
            self:emit('MOVE',r,self:expr(node.right)); self:patch(jump,self:pc())
        else
            -- CONCAT stages operands in temporaries even for own locals.
            local left=node.op=='..' and {register=self:expr(node.left)} or self:operand(node.left)
            local b=self:expr(node.right)
            local a=self:materialize(left)
            if not binary[node.op] then fail(self,node,'unsupported binary operator '..tostring(node.op)) end
            self:emit('BIN',r,a,b,binary[node.op])
        end
        return r
    elseif tag=='Index' then
        local reference=self:operand(node.object); local key=self:expr(node.key)
        local object=self:materialize(reference); local r=self:reg()
        self:emit('GETTABLE',r,object,key); return r
    elseif tag=='Function' then
        local child=C.new(self,node.vararg or false)
        for _,name in ipairs(node.params or {}) do
            child.proto.params[#child.proto.params+1]=child:declare(name)
        end
        child:block(node.body,false)
        child:emit('RETURN0')
        local id=#self.proto.children+1; self.proto.children[id]=child.proto
        local r=self:reg(); self:emit('CLOSURE',r,id); return r
    elseif tag=='Table' then
        local r=self:reg(); local arrayHint=0
        for _,field in ipairs(node.fields or {}) do
            if not field.key then arrayHint=arrayHint+1 end
        end
        self:emit('NEWTABLE',r,arrayHint)
        local index=1
        for i,field in ipairs(node.fields or {}) do
            if field.key then
                local reference=self:operand(field.key); local value=self:expr(field.value)
                local key=self:materialize(reference)
                self:emit('SETTABLE',r,key,value)
            elseif i==#node.fields and expands(field.value) then
                self:emit('SETLIST',r,index,self:multi(field.value))
            else
                local key=self:literal('number',index); local value=self:expr(field.value)
                self:emit('SETTABLE',r,key,value); index=index+1
            end
        end
        return r
    elseif tag=='IfExpr' then
        local condition=self:expr(node.condition); local r=self:reg()
        local no=self:emit('JMPIF',condition,0,0)
        self:emit('MOVE',r,self:expr(node.yes)); local finish=self:emit('JMP',0)
        self:patch(no,self:pc()); self:emit('MOVE',r,self:expr(node.no))
        self:patch(finish,self:pc()); return r
    elseif tag=='Interpolate' then
        -- Native interpolation is a format call: arguments all evaluate before
        -- any __tostring conversion runs, then formatting proceeds left-to-right.
        local values={}
        for i,part in ipairs(node.parts or {}) do values[i]=self:expr(part) end
        local r=self:literal('string','')
        for i,part in ipairs(node.parts or {}) do
            local value=values[i]
            if part.tag~='String' then
                local converted=self:reg(); self:emit('TOSTRING',converted,value)
                value=converted
            end
            self:emit('BIN',r,r,value,binary['..'])
        end
        return r
    end
    fail(self,node,'unsupported expression '..tostring(tag))
end

function C:block(block,scope)
    if scope then self:pushScope() end
    for _,node in ipairs(block.body or {}) do self:statement(node) end
    if scope then self:popScope() end
end

function C:loop(kind)
    local loop={kind=kind,breaks={},continues={},continueScopes={}}
    self.loops[#self.loops+1]=loop; return loop
end
function C:endLoop(loop,continueTarget,breakTarget)
    for _,pc in ipairs(loop.continues) do self:patch(pc,continueTarget) end
    for _,pc in ipairs(loop.breaks) do self:patch(pc,breakTarget) end
    self.loops[#self.loops]=nil
end

function C:statement(node)
    local previous=self.currentLine
    self.currentLine=node.line or previous
    self:compileStatement(node)
    self.currentLine=previous
end

function C:compileStatement(node)
    local tag=node.tag
    if tag=='Local' then
        local values=self:rhs(node.values,#node.names)
        -- All initializers run before any name in this declaration enters scope.
        for i,name in ipairs(node.names) do
            self:emit('NEWLOCAL',self:declare(name,node.readonly),values[i])
        end
    elseif tag=='LocalFunction' then
        local slot=self:declare(node.name,node.readonly); local nilreg=self:literal('nil')
        self:emit('NEWLOCAL',slot,nilreg)
        local value=self:expr(node.value); self:emit('SETLOCAL',slot,value)
    elseif tag=='Assign' then
        local addresses={}
        for i,target in ipairs(node.targets) do addresses[i]=self:address(target) end
        -- Native assignment conflict handling saves a table operand if a name
        -- in the same target list would otherwise overwrite its local register.
        local assignedLocals={}
        for _,address in ipairs(addresses) do
            if address.kind=='local' then assignedLocals[address.index]=true end
        end
        for _,address in ipairs(addresses) do
            if address.kind=='index' then
                for _,operand in ipairs({address.object,address.key}) do
                    if operand.binding and assignedLocals[operand.binding.index] then
                        operand.register=self:materialize(operand); operand.binding=nil
                    end
                end
            end
        end
        local values=self:rhs(node.values,#addresses)
        local written={}
        for i,address in ipairs(addresses) do
            local rhs=self:localOperand(node.values[i])
            local selfAssignment=address.kind=='local' and rhs and address.index==rhs.index
                and not written[address.index]
            if not selfAssignment then
                self:write(address,values[i])
            end
            if address.kind=='local' then written[address.index]=true end
        end
    elseif tag=='CompoundAssign' then
        local address=self:address(node.target)
        local left=(address.kind~='local' or node.op=='..') and self:readAddress(address) or nil
        local right=self:expr(node.value); local r=self:reg()
        if not left then left=self:readAddress(address) end
        if not binary[node.op] then fail(self,node,'unsupported compound operator '..tostring(node.op)) end
        self:emit('BIN',r,left,right,binary[node.op]); self:write(address,r)
    elseif tag=='CallStmt' then self:call(node.expression,'discard')
    elseif tag=='Return' then
        local values=node.values or {}
        if #values==0 then self:emit('RETURN0')
        elseif #values==1 and not expands(values[1]) then self:emit('RETURN1',self:expr(values[1]))
        elseif #values==1 then self:emit('RETURN',self:multi(values[1]))
        else self:emit('RETURN',self:list(values)) end
    elseif tag=='Do' then self:block(node.body,true)
    elseif tag=='If' then
        local exits={}
        for _,clause in ipairs(node.clauses) do
            local condition=self:expr(clause.condition); local nextClause=self:emit('JMPIF',condition,0,0)
            self:block(clause.body,true); exits[#exits+1]=self:emit('JMP',0)
            self:patch(nextClause,self:pc())
        end
        if node.elseBody then self:block(node.elseBody,true) end
        for _,pc in ipairs(exits) do self:patch(pc,self:pc()) end
    elseif tag=='While' then
        local start=self:pc(); local condition=self:expr(node.condition)
        local exit=self:emit('JMPIF',condition,0,0); local loop=self:loop(tag)
        self:block(node.body,true); self:emit('JMP',start)
        self:patch(exit,self:pc()); self:endLoop(loop,start,self:pc())
    elseif tag=='Repeat' then
        local start=self:pc(); local loop=self:loop(tag); self:pushScope()
        self:block(node.body,false); local conditionStart=self:pc()
        local previousReads=self.conditionReads; self.conditionReads={}
        local condition=self:expr(node.condition)
        for _,visible in ipairs(loop.continueScopes) do
            for slot in pairs(self.conditionReads) do
                if not visible[slot] then fail(self,node,'continue skips a local used by the repeat condition') end
            end
        end
        self.conditionReads=previousReads
        self:emit('JMPIF',condition,start,0); self:popScope()
        self:endLoop(loop,conditionStart,self:pc())
    elseif tag=='NumericFor' then
        local control=self:expr(node.start); local limit=self:expr(node.finish)
        local step=node.step and self:expr(node.step) or self:literal('number',1)
        self:emit('FORPREP',control,limit,step)
        local zero=self:literal('number',0); local positive=self:reg()
        self:emit('BIN',positive,step,zero,binary['>'])
        local start=self:pc(); local descending=self:emit('JMPIF',positive,0,0)
        local condition=self:reg(); self:emit('BIN',condition,control,limit,binary['<='])
        local checked=self:emit('JMP',0); self:patch(descending,self:pc())
        self:emit('BIN',condition,control,limit,binary['>=']); self:patch(checked,self:pc())
        local exit=self:emit('JMPIF',condition,0,0)
        self:pushScope(); local slot=self:declare(node.name)
        self:emit('NEWLOCAL',slot,control); local loop=self:loop(tag)
        self:block(node.body,true)
        local continueTarget=self:pc(); self:emit('BIN',control,control,step,binary['+'])
        self:emit('JMP',start); self:popScope()
        self:patch(exit,self:pc()); self:endLoop(loop,continueTarget,self:pc())
    elseif tag=='GenericFor' then
        local initial=self:list(node.values); local triple=self:reg()
        self:emit('ITERPREP',triple,initial)
        local iterator=self:reg(); self:emit('PICK',iterator,triple,1)
        local state=self:reg(); self:emit('PICK',state,triple,2)
        local control=self:reg(); self:emit('PICK',control,triple,3)
        local nilreg=self:literal('nil'); local start=self:pc()
        local args=self:reg(); self:emit('PACK',args); self:emit('PUSH',args,state); self:emit('PUSH',args,control)
        local values=self:reg(); self:emit('CALL',values,iterator,args); self:emit('PICK',control,values,1)
        local stopped=self:reg(); self:emit('BIN',stopped,control,nilreg,binary['=='])
        local exit=self:emit('JMPIF',stopped,0,1)
        self:pushScope()
        for i,name in ipairs(node.names) do
            local value=self:reg(); self:emit('PICK',value,values,i); self:emit('NEWLOCAL',self:declare(name),value)
        end
        local loop=self:loop(tag); self:block(node.body,true); self:emit('JMP',start)
        self:popScope(); self:patch(exit,self:pc()); self:endLoop(loop,start,self:pc())
    elseif tag=='Break' or tag=='Continue' then
        local loop=self.loops[#self.loops]
        if not loop then fail(self,node,tag:lower()..' outside a loop') end
        local list=tag=='Break' and loop.breaks or loop.continues
        list[#list+1]=self:emit('JMP',0)
        if tag=='Continue' and loop.kind=='Repeat' then
            local visible={}
            for _,scope in ipairs(self.scopes) do
                for _,binding in pairs(scope) do visible[binding.index]=true end
            end
            loop.continueScopes[#loop.continueScopes+1]=visible
        end
    else fail(self,node,'unsupported statement '..tostring(tag)) end
end

function M.compile(ast,options)
    options=options or {chunkname=ast.chunkname}
    local compiler=C.new(nil,true,options)
    compiler:block(ast,false)
    compiler:emit('RETURN0')
    return compiler.proto
end

M.binaryOperators=binary
M.unaryOperators=unary
return M
