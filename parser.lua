-- Recursive descent statement parser and Pratt expression parser; runs on Lua 5.1.
local lexer = require("src.lexer")
local M = {}

function M.parse(source, chunkname, expressionOnly, initialLine)
    local tokens, pos = lexer.lex(source, chunkname, initialLine), 1
    chunkname = chunkname or "input"
    local function token(offset) return tokens[pos + (offset or 0)] or tokens[#tokens] end
    local function is(kind) return token().kind == kind end
    local function fail(message)
        local t = token()
        error(chunkname .. ":" .. t.line .. ":" .. (t.column or 1) .. ": " .. message .. " near '" .. tostring(t.value) .. "'", 0)
    end
    local function take(kind)
        if kind and not is(kind) then fail("expected '" .. kind .. "'") end
        local t = token(); pos = pos + 1; return t
    end
    local function accept(kind) if is(kind) then return take() end end
    local function name() return take("name").value end
    local function node(tag, fields, atline, atcolumn)
        fields = fields or {}
        fields.tag,fields.line,fields.column=tag,atline or token().line,atcolumn or 1
        fields.chunkname=chunkname
        return fields
    end
    local expression, block, statement, functionbody, parsetype, primary

    local function attributes()
        while accept("@") do
            local attribute = name()
            if attribute ~= "native" and attribute ~= "checked" and attribute ~= "deprecated" then fail("unknown function attribute '" .. attribute .. "'") end
        end
    end

    local function genericparams()
        if not accept("<") then return end
        repeat
            if accept("...") then name() else name(); accept("...") end
            if accept("=") then parsetype() end
        until not accept(",")
        take(">")
    end

    -- Type syntax is consumed structurally, never by deleting source lines.
    local function typeatom()
        if accept("...") then typeatom(); return end
        if is("<") then genericparams(); typeatom(); return end
        if accept("(") then
            if not is(")") then
                repeat
                    if is("name") and token(1).kind == ":" then take(); take(":") end
                    parsetype()
                until not accept(",")
            end
            take(")")
            if accept("->") then parsetype() end
        elseif accept("{") then
            while not is("}") do
                if is("name") and (token().value == "read" or token().value == "write") and token(1).kind ~= ":" and token(1).kind ~= "?" then take() end
                if accept("[") then parsetype(); take("]"); take(":"); parsetype()
                elseif is("name") and (token(1).kind == ":" or token(1).kind == "?") then
                    take(); accept("?"); take(":"); parsetype()
                else parsetype() end
                if not accept(",") and not accept(";") then break end
            end
            take("}")
        elseif is("name") then
            local word = take().value
            if word == "typeof" and accept("(") then expression(); take(")")
            else
                while accept(".") do name() end
                if accept("<") then
                    if not is(">") then repeat parsetype() until not accept(",") end
                    take(">")
                end
            end
        elseif is("string") or is("true") or is("false") or is("nil") then take()
        else fail("expected a type") end
        while accept("?") or accept("...") do end
    end
    parsetype = function()
        if not accept("|") then accept("&") end
        typeatom()
        while accept("|") or accept("&") do typeatom() end
    end
    local function annotation() if accept(":") then parsetype() end end

    local precedence = { ["or"]=1,["and"]=2,["=="]=3,["~="]=3,["<"]=3,["<="]=3,[">"]=3,[">="]=3,[".."]=4,["+"]=5,["-"]=5,["*"]=6,["/"]=6,["//"]=6,["%"]=6,["^"]=8 }
    local function exprlist()
        local values = {expression()}
        while accept(",") do values[#values + 1] = expression() end
        return values
    end
    local function callargs()
        if accept("(") then
            local args = is(")") and {} or exprlist(); take(")"); return args
        elseif is("string") then local t = take(); return {node("String", {value=t.value}, t.line)}
        elseif is("{") then return {primary(true)} end
        fail("expected function arguments")
    end
    local function ifexpr()
        local atline = take("if").line
        local condition = expression(); take("then"); local yes = expression()
        local no
        if is("elseif") then
            -- The nested form follows the same grammar without an extra `if` token.
            take("elseif")
            local function tail()
                local cond = expression(); take("then"); local y = expression(); local n
                if accept("elseif") then n = tail() else take("else"); n = expression() end
                return node("IfExpr", {condition=cond, yes=y, no=n}, atline)
            end
            no = tail()
        else take("else"); no = expression() end
        return node("IfExpr", {condition=condition, yes=yes, no=no}, atline)
    end
    primary = function(noSuffix)
        local t, value = token(), nil
        if accept("nil") then value = node("Nil", nil, t.line)
        elseif accept("true") then value = node("Boolean", {value=true}, t.line)
        elseif accept("false") then value = node("Boolean", {value=false}, t.line)
        elseif is("number") then take(); value = node("Number", {value=t.value}, t.line)
        elseif is("string") then take(); value = node("String", {value=t.value}, t.line)
        elseif is("interp") then
            take()
            local parts = {}
            for _,part in ipairs(t.value) do
                if part.kind == "text" then parts[#parts + 1] = node("String", {value=part.value}, part.line)
                else
                    local item = M.parse(part.source, chunkname, true, part.line)
                    -- A literal expression inside braces still requires native
                    -- conversion; retain that distinction from literal text.
                    parts[#parts + 1] = node("Paren", {value=item}, part.line)
                end
            end
            value = node("Interpolate", {parts=parts}, t.line)
        elseif is("name") then take(); value = node("Name", {name=t.value}, t.line, t.column)
        elseif accept("...") then value = node("Vararg", nil, t.line)
        elseif accept("(") then value = node("Paren", {value=expression()}, t.line); take(")")
        elseif accept("function") then value = functionbody(t.line)
        elseif is("@") then attributes(); local fn = take("function"); value = functionbody(fn.line)
        elseif is("if") then value = ifexpr()
        elseif accept("{") then
            local fields = {}
            while not is("}") do
                local key, fieldvalue
                if accept("[") then key = expression(); take("]"); take("="); fieldvalue = expression()
                elseif is("name") and token(1).kind == "=" then
                    local k = take(); take("="); key = node("String", {value=k.value}, k.line); fieldvalue = expression()
                else fieldvalue = expression() end
                fields[#fields + 1] = {key=key, value=fieldvalue}
                if not accept(",") and not accept(";") then break end
            end
            take("}"); value = node("Table", {fields=fields}, t.line)
        else fail("expected an expression") end
        if noSuffix then return value end
        local prefix = value.tag == "Name" or value.tag == "Paren"
        while true do
            if not prefix and not is("::") then break
            elseif accept("[") then local key = expression(); take("]"); value = node("Index", {object=value,key=key}, t.line)
            elseif accept(".") then local k = take("name"); value = node("Index", {object=value,key=node("String",{value=k.value},k.line)}, t.line)
            elseif accept(":") then local method = name(); value = node("MethodCall", {object=value,method=method,args=callargs()}, t.line)
            elseif is("(") or is("{") or is("string") then value = node("Call", {callee=value,args=callargs()}, t.line)
            elseif accept("::") then parsetype()
            else break end
        end
        return value
    end
    expression = function(minimum)
        minimum = minimum or 0
        local left
        if is("-") or is("not") or is("#") then
            local op = take(); left = node("Unary", {op=op.value,value=expression(7)}, op.line)
        else left = primary() end
        while true do
            local op, power = token().kind, precedence[token().kind]
            if not power or power < minimum then break end
            local atline = take().line
            left = node("Binary", {op=op,left=left,right=expression((op == "^" or op == "..") and power or power + 1)}, atline)
        end
        return left
    end
    functionbody = function(atline, method)
        genericparams(); take("(")
        local params, vararg = {}, false
        if method then params[1] = "self" end
        if not is(")") then
            repeat
                if accept("...") then vararg = true; annotation(); break end
                params[#params + 1] = name(); annotation()
            until not accept(",")
        end
        take(")"); annotation()
        local body = block({["end"]=true}); take("end")
        return node("Function", {params=params,vararg=vararg,body=body}, atline)
    end
    local function target(value)
        if value.tag ~= "Name" and value.tag ~= "Index" then fail("invalid assignment target") end
        return value
    end
    local enders = {["end"]=true,["else"]=true,["elseif"]=true,["until"]=true,["eof"]=true,[";"]=true}
    statement = function()
        local t = token()
        if is("@") then
            attributes()
            if not is("function") and not (is("local") and token(1).kind == "function") and not (is("name") and token().value == "const" and token(1).kind == "function") then
                fail("function attributes must precede a function declaration")
            end
            return statement()
        elseif accept(";") then return nil
        elseif is("name") and ((t.value == "type" and (token(1).kind == "name" or token(1).kind == "function")) or (t.value == "export" and token(1).value == "type")) then
            if t.value == "export" then take() end
            take() -- contextual `type`
            if accept("function") then
                name(); functionbody(t.line); accept(";"); return nil
            end
            name(); genericparams(); take("="); parsetype(); accept(";"); return nil
        elseif is("local") or (is("name") and t.value == "const" and (token(1).kind == "name" or token(1).kind == "function")) then
            take()
            local readonly = t.value == "const"
            if accept("function") then local n = name(); return node("LocalFunction", {name=n,value=functionbody(t.line),readonly=readonly}, t.line) end
            local names = {}
            repeat names[#names + 1] = name(); annotation() until not accept(",")
            local values = accept("=") and exprlist() or {}
            if readonly and #values == 0 then fail("missing initializer in const declaration") end
            return node("Local", {names=names,values=values,readonly=readonly}, t.line)
        elseif accept("function") then
            local n = take("name"); local value = node("Name", {name=n.value}, n.line)
            while accept(".") do local k = take("name"); value = node("Index", {object=value,key=node("String",{value=k.value},k.line)}, t.line) end
            local method = false
            if accept(":") then method = true; local k = take("name"); value = node("Index", {object=value,key=node("String",{value=k.value},k.line)}, t.line) end
            return node("Assign", {targets={value},values={functionbody(t.line, method)}}, t.line)
        elseif accept("if") then
            local clauses = {}
            repeat
                local condition = expression(); take("then")
                clauses[#clauses + 1] = {condition=condition,body=block({["elseif"]=true,["else"]=true,["end"]=true})}
            until not accept("elseif")
            local elseBody
            if accept("else") then elseBody = block({["end"]=true}) end
            take("end"); return node("If", {clauses=clauses,elseBody=elseBody}, t.line)
        elseif accept("while") then
            local condition = expression(); take("do"); local body = block({["end"]=true}); take("end")
            return node("While", {condition=condition,body=body}, t.line)
        elseif accept("repeat") then
            local body = block({["until"]=true}); take("until")
            return node("Repeat", {body=body,condition=expression()}, t.line)
        elseif accept("for") then
            local n = name(); annotation()
            if accept("=") then
                local start = expression(); take(","); local finish = expression(); local step
                if accept(",") then step = expression() end
                take("do"); local body = block({["end"]=true}); take("end")
                return node("NumericFor", {name=n,start=start,finish=finish,step=step,body=body}, t.line)
            else
                local names = {n}
                while accept(",") do names[#names + 1] = name(); annotation() end
                take("in"); local values = exprlist(); take("do"); local body = block({["end"]=true}); take("end")
                return node("GenericFor", {names=names,values=values,body=body}, t.line)
            end
        elseif accept("do") then local body = block({["end"]=true}); take("end"); return node("Do", {body=body}, t.line)
        elseif accept("return") then return node("Return", {values=enders[token().kind] and {} or exprlist()}, t.line)
        elseif accept("break") then return node("Break", nil, t.line)
        elseif is("name") and t.value == "continue" and not ({["="]=true,[","]=true,["+="]=true,["-="]=true,["*="]=true,["/="]=true,["//="]=true,["%="]=true,["^="]=true,["..="]=true,["("]=true,["{"]=true,["string"]=true,["["]=true,["."]=true,[":"]=true,["::"]=true})[token(1).kind] then
            take(); return node("Continue", nil, t.line)
        else
            local value = expression(9)
            if is("=") or is(",") then
                local targets = {target(value)}
                while accept(",") do targets[#targets + 1] = target(expression(9)) end
                take("="); return node("Assign", {targets=targets,values=exprlist()}, t.line)
            elseif ({["+="]=true,["-="]=true,["*="]=true,["/="]=true,["//="]=true,["%="]=true,["^="]=true,["..="]=true})[token().kind] then
                local op = take().value
                return node("CompoundAssign", {target=target(value),op=op:sub(1,-2),value=expression()}, t.line)
            elseif value.tag == "Call" or value.tag == "MethodCall" then return node("CallStmt", {expression=value}, t.line)
            else fail("expected assignment or function call") end
        end
    end
    block = function(stops)
        local atline, body = token().line, {}
        while not stops[token().kind] and not is("eof") do
            local before = pos; local item = statement()
            if item then
                body[#body + 1] = item
                if item.tag == "Return" or item.tag == "Break" or item.tag == "Continue" then
                    accept(";")
                    if not stops[token().kind] and not is("eof") then
                        fail("expected end of block after " .. item.tag:lower())
                    end
                end
            end
            if pos == before then fail("parser made no progress") end
        end
        return node("Block", {body=body}, atline)
    end
    if expressionOnly then local value = expression(); take("eof"); return value end
    local ast = block({["eof"]=true}); take("eof"); return ast
end

return M
