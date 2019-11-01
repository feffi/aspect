local setmetatable = setmetatable
local tostring = tostring
local pairs = pairs
local type = type
local ipairs = ipairs
local find = string.find
local insert = table.insert
local remove = table.remove
local concat = table.concat
local tokenizer = require("aspect.tokenizer")
local tags = require("aspect.tags")
local tests = require("aspect.tests")
local err = require("aspect.err")
local write = require("pl.pretty").write
local dump = require("pl.pretty").dump
local quote_string = require("pl.stringx").quote_string
local strcount = require("pl.stringx").count
local tablex = require("pl.tablex")
local compiler_error = err.compiler_error
local sub = string.sub
local strlen = string.len
local pcall = pcall
local config = require("aspect.config")
local import_type = config.macro.import_type
local reserved_words = config.compiler.reserved_words
local reserved_vars = config.compiler.reserved_vars
local math_ops = config.compiler.math_ops
local comparison_ops = config.compiler.comparison_ops
local logic_ops = config.compiler.logic_ops
local loop_keys = config.loop.keys
local tag_type = config.compiler.tag_type
local func = require("aspect.funcs")


--- @class aspect.compiler
--- @field aspect aspect.template
--- @field name string
--- @field macros table<table> table of macros with their code (witch array)
--- @field extends string|fun
--- @field extends_expr boolean
--- @field import table
--- @field line number
--- @field tok aspect.tokenizer
--- @field utils aspect.compiler.utils
--- @field code table stack of code. Each level is isolated code (block or macro). 0 level is body
local compiler = {
    version = 1,
}

--- @class aspect.compiler.utils
local utils = {}

local mt = {__index = compiler}

--- @param aspect aspect.template
--- @param name string
--- @return aspect.compiler
function compiler.new(aspect, name)
    return setmetatable({
        aspect = aspect,
        name = name,
        line = 1,
        prev_line = 1,
        body = {},
        code = {},
        macros = {},
        extends = nil,
        blocks = {},
        uses = {},
        vars = {},
        deps = {},
        tags = {},
        idx  = 0,
        use_vars = {},
        tag_type = nil,
        import = {}
    }, mt)
end

--- Start compiler
--- @param source string source code of the template
--- @return boolean ok or not ok
--- @return aspect.error if not ok returns error
function compiler:run(source)
    local ok, e = pcall(self.parse, self, source)
    if ok then
        return true
    else
        return false, err.new(e):set_name(self.name, self.line)
    end
end

function compiler:get_code()

    local code = {
        "local _self = {",
        "\tv = " .. self.version .. ",",
        "\tname = " .. quote_string(self.name) .. ",",
        "\tblocks = {},",
        "\tmacros = {},",
        "\tvars = {},",
    }
    if self.extends then
        if self.extends.static then
            insert(code,"\textends = " .. self.extends.value .. ",")
        else
            insert(code,"\textends = true")
        end
    end
    insert(code, "}\n")

    insert(code, "function _self.body(__, ...)")
    if self.extends then
        insert(code, "\t_context = ...")
        insert(code, "\treturn " .. self.extends.value)
    elseif #self.body then
        insert(code, "\t_context = ...")
        insert(code, "\t__:push_state(_self, 1)")
        for _, v in ipairs(self.body) do
            insert(code, "\t" .. v)
        end
        insert(code, "\t_context = nil")
        insert(code, "\t__:pop_state()")
    end
    insert(code, "end\n")

    if self.blocks then
        for n, b in pairs(self.blocks) do
            insert(code, "_self.blocks." .. n .. " = {")
            insert(code, "\tparent = " .. tostring(b.parent) .. ",")
            insert(code, "\tdesc = " .. quote_string(b.desc or "") .. ",")
            insert(code, "\tvars = " .. write(b.vars or {}, "\t") .. ",")
            insert(code, "}")
            insert(code, "function _self.blocks." .. n .. ".body(__, ...)")
            insert(code, "\t_context = ...")
            for _, v in ipairs(b.code) do
                insert(code, "\t" .. v)
            end
            insert(code, "\t_context = nil")
            insert(code, "end\n")
        end
    end

    if self.macros then
        for n, m in pairs(self.macros) do
            insert(code, "function _self.macros." .. n .. "(__, _context)")
            for _, v in ipairs(m) do
                insert(code, "\t" .. v)
            end
            insert(code, "end\n")
        end
    end

    insert(code, "return _self")
    return concat(code, "\n")
end

function compiler:parse(source)
    local l = 1
    local tag_pos = find(source, "{", l, true)
    self.body = {}
    self.code = {self.body}
    self.macros = {}
    self.blocks = {}
    while tag_pos do
        if l <= tag_pos - 1 then -- cut text before tag
            local frag = sub(source, l, tag_pos - 1)
            self:append_text(frag)
            self.line = self.line + strcount(frag, "\n")
        end
        local t, p = sub(source, tag_pos + 1, tag_pos + 1), tag_pos + 2
        if t == "{" then -- '{{'
            self.tag_type = tag_type.EXPRESSION
            local tok = tokenizer.new(sub(source, tag_pos + 2))
            self:append_expr(self:parse_expression(tok))
            if tok:is_valid() then
                compiler_error(tok, "syntax", "expecting end of tag")
            end
            local path = tok:get_path_as_string()
            l = tag_pos + 2 + strlen(path) + strlen(tok.finished_token) -- start tag pos + '{{' +  tag length + '}}'
            self.line = self.line + strcount(path, "\n")
            tok = nil
        elseif t == "%" then -- '{%'
            self.tag_type = tag_type.CONTROL
            local tok = tokenizer.new(sub(source, tag_pos + 2))
            local tag_name = 'tag_' .. tok:get_token()
            if tags[tag_name] then
                self:append_code(tags[tag_name](self, tok:next())) -- call tags.tag_{{ name }}(compiler, tok)
                if tok:is_valid() then
                    compiler_error(tok, "syntax", "expecting end of tag")
                end
            else
                compiler_error(nil, "syntax", "unknown tag '" .. tok:get_token() .. "'")
            end
            local path = tok:get_path_as_string()
            l = tag_pos + 2 + strlen(path) + strlen(tok.finished_token) -- start tag pos + '{%' + tag length + '%}'
            self.line = self.line + strcount(path, "\n")
            tok = nil
        elseif t == "#" then
            tag_pos = find(source, "#}", p, true)
            l = tag_pos + 2
        end
        self.tag_type = nil
        tag_pos = find(source, "{", tag_pos + 1, true)
    end
    self:append_text(sub(source, l))
end

function compiler:parse_var_name(tok, opts)
    opts = opts or {}
    opts.var_system = false
    if tok:is_word() then
        local var = tok:get_token()
        if var == "_context" or var == "__" or var == "_self" then
            opts.var_system = true
        else
            opts.var_system = false
        end
        tok:next()
        return var
    else
        compiler_error(tok, "syntax", "expecting variable name")
    end
end

--- Parse basic variable name like:
--- one
--- one.two
--- one["two"].three
--- @param tok aspect.tokenizer
function compiler:parse_variable(tok)
    if tok:is_word() then
        local var
        if tok:is('loop') then -- magick variable name {{ loop }}
            var = {"loop"}
            local tag, pos = self:get_last_tag('for')
            while tag do
                if tag.has_loop ~= true then
                    tag.has_loop = tag.has_loop or {}
                    local loop_key = tok:next():require("."):next():get_token()
                    if not loop_keys[loop_key] then
                        compiler_error(tok, "syntax", "expecting one of [" .. concat(tablex.keys(loop_keys), ", ") .. "]")
                    end
                    var[#var + 1] = '"' .. loop_key .. '"'
                    if loop_key == "parent" then
                        tag.has_loop.parent = true
                        tag, pos = self:get_last_tag('for', pos - 1)
                    else
                        tag.has_loop[loop_key] = true
                        tag = false
                    end
                end
                tok:next()
                --else
                --    tok:next()
                --    var = {"loop"}
            end
        elseif tok:is("_context") then -- magick variable name {{ _context }}
            tok:next()
            var = {"_context"}
        end
        --if remember and not self.var_names[tok:get_token()] then
        --    self.var_names[tok:get_token()] = remember
        --end
        if not var then
            var = {self:parse_var_name(tok)}
        end
        while tok:is(".") or tok:is("[") do
            local mode = tok:get_token()
            tok:next()
            if tok:is_word() then
                insert(var, '"' .. tok:get_token() .. '"')
                tok:next()
            elseif tok:is_string() then
                insert(var, tok:get_token())
                tok:next()
                if mode == "[" then
                    tok:require("]"):next()
                end
            else
                compiler_error(tok, "syntax", "expecting word or quoted string")
            end
        end
        if #var == 1 then
            return var[1]
        else
            return "__.v(" .. concat(var, ", ") .. ")"
        end
    else
        compiler_error(tok, "syntax", "expecting variable name")
    end
end

--- @param tok aspect.tokenizer
function compiler:parse_function(tok)
    local name, args = nil, {}
    if tok:is_word() then
        name = tok:get_token()
    else
        compiler_error(tok, "syntax", "expecting function name")
    end
    if not func.fn[name] then
        compiler_error(tok, "syntax", "function " .. name .. "() not found")
    end
    tok:next():require("("):next()
    if not tok:is(")") and func.args[name] then
        local i, hint = 1, func.args[name]
        while true do
            local key, value = nil, nil
            if tok:is_word() then
                if tok:is_next("=") then
                    key = tok:get_token()
                    tok:next():require("="):next()
                    value = self:parse_expression(tok)
                else
                    value = self:parse_expression(tok)
                end
            else
                value = self:parse_expression(tok)
            end
            if key then
                if tablex.find(hint, key) then
                    args[key] = value
                else
                    compiler_error(tok, "syntax", name .. "(): unknown argument <" .. key .. ">")
                end
            else
                if hint[i] then
                    args[ hint[i] ] = value
                else
                    compiler_error(tok, "syntax", name .. "(): unknown argument #" .. i)
                end
            end
            if tok:is(",") then
                tok:next()
            else
                break
            end
            i = i + 1
        end
    end
    tok:require(")"):next()
    if func.parsers[name] then
        return func.parsers[name](self, args)
    else
        return "__.fn." .. name .. "(__, {" .. compiler.utils.implode_hashes(args) .. "})"
    end
end

--- @param tok aspect.tokenizer
function compiler:parse_macro(tok)
    if tok:is("_self") then
        local name = tok:next():require("."):next():get_token()
        if not self.macros[name] then
            compiler_error(tok, "syntax", "Macro " .. name .. " not defined in this (" .. self.name .. ") template")
        end
        return "_self.macros." .. name .."(__, " .. self:parse_macro_args(tok:next():require("(")) .. ")", false
    elseif tok:is_word() then
        if tok:is_next(".") then
            local var = tok:get_token()
            if self.import[var] ~= import_type.GROUP then
                compiler_error(tok, "syntax", "Macro " .. var .. " not imported")
            end
            local name = tok:next():require("."):next():get_token()
            return "(" .. var .. "." .. name .. " and "
                    .. var .. "." .. name .. "(__, " .. self:parse_macro_args(tok:next()) .. "))", false
        elseif tok:is_next("(") then
            local name = tok:get_token()
            if self.import[name] ~= import_type.SINGLE then
                compiler_error(tok, "syntax", "Macro " .. name .. " not imported")
            end
            tok:next():require("(")
            return name .."(__, " .. self:parse_macro_args(tok) .. ")", false
        end
    end
end

--- Parse arguments for macros
--- @param tok aspect.tokenizer
function compiler:parse_macro_args(tok)
    tok:require("("):next()
    local i, args = 1, {}
    while true do
        local key, value = nil, nil
        if tok:is_word() then
            if tok:is_next("=") then
                key = tok:get_token()
                tok:next():require("="):next()
                value = self:parse_expression(tok)
            else
                value = self:parse_expression(tok)
            end
        else
            value = self:parse_expression(tok)
        end
        if key then
            args[ key ] = value
        else
            args[ i ] = value
        end
        if tok:is(",") then
            tok:next()
        else
            break
        end
        i = i + 1
    end
    tok:require(")"):next()
    args = compiler.utils.implode_hashes(args)
    if args then
        return "{ " .. args .. " }"
    else
        return "{}"
    end

end

--- Parse array (list or hash)
--- [1,2,3]
--- {"one": 1, "two": 2}
--- @param tok aspect.tokenizer
--- @param plain boolean return table without brackets
function compiler:parse_array(tok, plain)
    local vals = {}
    if tok:is("[") then
        tok:next()
        if tok:is("]") then
            return "{}"
        end
        while true do
            insert(vals, self:parse_expression(tok))
            if tok:is(",") then
                tok:next()
            elseif tok:is(":") then
                compiler_error(tok, "syntax", "list can't have named keys, use hash instead")
            else
                break
            end
        end
        tok:require("]"):next()
    elseif tok:is("{") then
        tok:next()
        if tok:is("}") then
            tok:next()
            return "{}"
        end
        while true do
            local key
            if tok:is_word() then
                key = '"' .. tok:get_token() .. '"'
                tok:next()
            elseif tok:is_string() or tok:is_number() then
                key = tok:get_token()
                tok:next()
            elseif tok:is("(") then
                key = self:parse_expression(tok)
            end
            insert(vals, "[" .. key .. "] = " .. self:parse_expression(tok:require(":"):next()))
            if tok:is(",") then
                tok:next()
            else
                break
            end
        end
        tok:require("}"):next()
    else
        compiler_error(tok, "syntax", "expecting list or hash")
    end
    if plain then
        return concat(vals, ", ")
    else
        return "{" .. concat(vals, ", ") .. "}"
    end
end

--- @param tok aspect.tokenizer
--- @return table
function compiler:parse_hash(tok)
    local hash = {}
    tok:require('{'):next()
    if tok:is("}") then
        tok:next()
        return hash
    end
    while true do
        local key
        if tok:is_word() then
            key = tok:get_token()
            tok:next()
        else
            compiler_error(tok, "syntax", "expecting hash key")
        end

        hash[key] = self:parse_expression(tok:require(":"):next())
        if tok:is(",") then
            tok:next()
        else
            break
        end
    end
    tok:require("}"):next()
    return hash
end

--- @param tok aspect.tokenizer
--- @param info table
--- @return string
function compiler:parse_filters(tok, var, info)
    info = info or {}
    while tok:is("|") do -- parse pipeline filter
        if tok:next():is_word() then
            local filter = tok:get_token()
            if filter == "raw" then
                info.raw = true
            end
            local args, no = nil, 1
            tok:next()
            if tok:is("(") then
                args = {}
                while not tok:is(")") and tok:is_valid() do -- parse arguments of the filter
                    tok:next()
                    local key
                    if tok:is_word() then
                        key = tok:get_token()
                        tok:next():require("="):next()
                        args[key] = self:parse_expression(tok)
                    else
                        args[no] = self:parse_expression(tok)
                    end
                    no = no + 1
                end
                tok:next()
            end
            if args then
                var = "__.f['" .. filter .. "'](" .. var .. ", " .. concat(args, ", ") .. ")"
            else
                var = "__.f['" .. filter .. "'](" .. var .. ")"
            end
        else
            compiler_error(tok, "syntax", "expecting filter name")
        end
    end
    return var
end

--- @param tok aspect.tokenizer
--- @param info table
function compiler:parse_value(tok, info)
    local var
    info = info or {}
    info.type = nil
    if tok:is_word() then -- is variable name
        if tok:is_next("(") then
            if self.import[tok:get_token()] == import_type.SINGLE then
                var = self:parse_macro(tok)
                info.type = "nil"
            else
                var = self:parse_function(tok)
                info.type = "any"
            end
        elseif tok:is_seq{"word", ".", "word", "("} then
            var = self:parse_macro(tok)
            info.type = "nil"
        else
            var = self:parse_variable(tok)
            info.type = "any"
        end
    elseif tok:is_string() then -- is string or number
        var = tok:get_token()
        tok:next()
        info.type = "string"
    elseif tok:is_number() then
        var = tok:get_token()
        tok:next()
        info.type = "number"
    elseif tok:is("[") or tok:is("{") then -- is list or hash
        var = self:parse_array(tok)
        info.type = "table"
    elseif tok:is("(") then -- is expression
        var = self:parse_expression(tok:next())
        tok:require(")"):next()
        info.type = "expr"
    elseif tok:is("true") or tok:is("false") then -- is regular true/false/nil
        var = tok:get_token()
        tok:next()
        info.type = "boolean"
    elseif tok:is("null") or tok:is("nil") then -- is null
        var = 'nil'
        tok:next()
    else
        compiler_error(tok, "syntax", "expecting any value")
    end
    if tok:is("|") then
        var = self:parse_filters(tok, var)
        info.type = "any"
    end
    return var
end

--- Parse any expression (math, logic, string e.g.)
--- @param tok aspect.tokenizer
--- @param opts table|nil
function compiler:parse_expression(tok, opts)
    opts = opts or {}
    opts.bools = opts.bools or 0
    local elems = {}
    local comp_op = false -- only one comparison may be in the expression
    local logic_op = false
    while true do
        local info = {}
        local not_op, minus_op
        -- 1. checks unary operator 'not'
        if tok:is("not") then
            not_op = "not "
            tok:next()
        elseif tok:is("-") then
            minus_op = true
            tok:next()
        end
        -- 2. parse value
        local element = self:parse_value(tok, info)
        if minus_op then
            if info.type == "number" then
                element = "-" .. element
            elseif info.type == "expr" then
                element = "-(__.tonumber" .. element .. " or 0)"
            else
                element = "-(__.tonumber(" .. element .. ") or 0)"
            end
        end
        -- 3. check operator 'in' or 'not in' and 'is' or 'is not'
        if tok:is("in") or tok:is("not") then
            if tok:is("not") then
                insert(elems, "not")
            end
            tok:require("in"):next()
            element = "__.f['in'](" .. element .. ", " ..  self:parse_expression(tok) .. ")"
        elseif tok:is("is") then
            element = self:parse_test(tok, element)
        end
        if logic_op then
            opts.bools  = opts.bools + 1
            insert(elems, (not_op or "") .. "__.b(" .. element .. ")")
        elseif not_op then
            opts.bools  = opts.bools + 1
            insert(elems, not_op .. "__.b(" .. element .. ")")
        else
            insert(elems, element)
        end
        local op = false
        comp_op = false

        -- 4. checks and parse math/logic/comparison/concat operator
        if math_ops[tok:get_token()] then -- math
            insert(elems, math_ops[tok:get_token()])
            tok:next()
            op = true
            logic_op = false
        elseif comparison_ops[tok:get_token()] then -- comparison
            if comp_op then
                compiler_error(tok, "syntax", "only one comparison operator may be in the expression")
            end
            insert(elems, comparison_ops[tok:get_token()])
            tok:next()
            op = true
            comp_op = true
            logic_op = false
        elseif logic_ops[tok:get_token()] then -- logic
            if not logic_op then
                opts.bools  = opts.bools + 1
                elems[#elems] = "__.b(" .. elems[#elems] .. ")"
            end
            insert(elems, logic_ops[tok:get_token()])
            tok:next()
            op = true
            comp_op = false
            logic_op = true
        elseif tok:is("~") then -- concat
            insert(elems, "..")
            tok:next()
            op = true
            logic_op = false
        else
            logic_op = false
        end
        -- 5. if no more math/logic/comparison/concat operators found - work done
        if not op then
            break
        end
    end
    if comp_op then -- comparison with nothing?
        compiler_error(tok, "syntax", "expecting expression statement")
    end
    opts.count = (#elems + 1)/2
    opts.all_bools = logic_op == opts.count -- all elements converted to boolean?
    return concat(elems, " ")
end

--- Append any text
--- @param text string
function compiler:append_text(text)
    local tag = self:get_last_tag()
    local line = self:get_checkpoint()
    local code = self.code[#self.code]
    if line then
        insert(code, line)
    end
    if tag and tag.append_text then
        insert(code, tag.append_text(tag, text))
    else
        insert(code, "__(" .. quote_string(text) .. ")")
    end
end

function compiler:append_expr(lua)
    local tag = self:get_last_tag()
    local line = self:get_checkpoint()
    local code = self.code[#self.code]
    if line then
        insert(code, line)
    end
    if lua then
        if tag and tag.append_expr then
            insert(code, tag.append_expr(tag, lua))
        else
            insert(code, "__:e(" .. lua .. ")")
        end
    end
end

function compiler:append_code(lua)
    local tag = self:get_last_tag()
    local line= self:get_checkpoint()
    local code = self.code[#self.code]
    if line then
        insert(code, line)
    end
    if type(lua) == "table" then
        for _, l in ipairs(lua) do
            if tag and tag.append_code then
                insert(code, tag.append_code(tag, l))
            else
                insert(code, l)
            end
        end
    elseif lua then
        if tag and tag.append_code then
            insert(code, tag.append_code(tag, lua))
        else
            insert(code, lua)
        end
    end
end

function compiler:get_checkpoint()
    if self.prev_line ~= self.line then
        self.prev_line = self.line
        return "__.line = " .. self.line
    else
        return nil
    end
end

--- Add local variable name to scope (used for includes and blocks)
--- @param name string
function compiler:push_var(name)
    if #self.tags > 0 then
        local tag = self.tags[#self.tags]
        if not tag.vars then
            tag.vars = {name = true}
        else
            tag.vars[name] = true
        end
    else
        self.vars[name] = true
    end
end

--- Returns all variables name defined in the scope (without global)
--- @return table|nil list of variables like ["variable"] = variable
function compiler:get_local_vars()
    local vars, c = {}, 0
    for k, _ in pairs(self.vars) do
        vars[k] = k
        c = c  + 1
    end
    for _, tag in ipairs(self.tags) do
        if tag.vars then
            for k, _ in pairs(self.vars) do
                if not vars[k] then
                    vars[k] = k
                    c = c + 1
                end
            end
        end
    end

    if c > 0 then
        return vars
    else
        return nil
    end
end

--- Push the tag in tag's stacks
--- @param name string the tag name
--- @param code_space table|nil for lua code
function compiler:push_tag(name, code_space, code_space_name)
    self.idx = self.idx + 1
    local tag = {
        id = self.idx,
        name = name,
        line = self.line
    }
    if code_space then
        insert(self.code, code_space)
        if not code_space_name then
            code_space_name = "nil"
        else
            code_space_name = quote_string(code_space_name)
        end
        code_space[#code_space + 1] = "__:push_state(_self, " .. self.line .. ", " .. code_space_name .. ")"
        self.prev_line = self.line
        tag.code_space_no = #self.code
    end
    tag.code_space = self.code[#self.code]
    tag.code_start_line = #tag.code_space

    local prev = self.tags[#self.tags]
    if prev then
        if prev.append_text then
            tag.append_text = prev.append_text
        end
        if prev.append_expr then
            tag.append_expr = prev.append_expr
        end
        if prev.append_code then
            tag.append_code = prev.append_code
        end
    end
    insert(self.tags, tag)
    return tag
end

--- Remove tag from stack
--- @param name string the tag name
function compiler:pop_tag(name)
    if #self.tags then
        local tag = self.tags[#self.tags]
        if tag.name == name then
            if tag.code_space_no then
                if tag.code_space_no ~= #self.code then -- dummy protection
                    compiler_error(nil, "compiler", "invalid code space layer in the tag")
                else
                    local prev = remove(self.code)
                    prev[#prev + 1] = "__:pop_state()"
                end
            end
            return remove(self.tags)
        else
            compiler_error(nil, "syntax",
               "unexpected tag 'end" .. name .. "'. Expecting tag 'end" .. tag.name .. "' (opened on line " .. tag.line .. ")")
        end
    else
        compiler_error(nil, "syntax", "unexpected tag 'end" .. name .. "'. Tag ".. name .. " never opened")
    end
end

--- Returns last tag from stack
--- @param name string if set then returns last tag with this name
--- @param from number|nil stack offset
--- @return table|nil
--- @return number|nil stack position
function compiler:get_last_tag(name, from)
    if name then
        if from and from < 1 then
            return nil
        end
        from = from or #self.tags
        if #self.tags > 0 then
            for i=from, 1, -1 do
                if self.tags[i].name == name then
                    return self.tags[i], i
                end
            end
        end
    elseif #self.tags then
        return self.tags[#self.tags], #self.tags
    end
    return nil
end



--- Merge two tables and returns lua representation. Value of table are expressions.
--- @param t1 table|nil
--- @param t2 table|nil
--- @return string|nil
function utils.implode_hashes(t1, t2)
    local r = {}
    if t1 then
        for k,v in pairs(t1) do
            if type(k) == "number" then
                r[#r + 1] = '[' .. k .. '] = ' .. v
            else
                r[#r + 1] = '["' .. k .. '"] = ' .. v
            end
        end
        if t2 then
            for k,v in pairs(t2) do
                if not t1[k] then
                    if type(k) == "number" then
                        r[#r + 1] = '[' .. k .. '] = ' .. v
                    else
                        r[#r + 1] = '["' .. k .. '"] = ' .. v
                    end
                end
            end
        end
    elseif t2 then
        for k,v in pairs(t2) do
            if type(k) == "number" then
                r[#r + 1] = '[' .. k .. '] = ' .. v
            else
                r[#r + 1] = '["' .. k .. '"] = ' .. v
            end
        end
    end
    if #r > 0 then
        return concat(r, ",")
    else
        return nil
    end
end

--- Prepend the table to another table
--- @param from table
--- @param to table
function utils.prepend_table(from, to)
    for i, v in ipairs(from) do
        insert(to, i, v)
    end
end

--- Prepend the table to another table
--- @param from table
--- @param to table
function utils.append_table(from, to)
    for _, v in ipairs(from) do
        insert(to, v)
    end
end

--- Join elements of the table
--- @param t table|string
--- @param delim string
function utils.join(t, delim)
    if type(t) == "table" then
        return concat(t, delim)
    else
        return tostring(t)
    end
end

compiler.utils = utils

return compiler