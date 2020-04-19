local tonumber = tonumber
local tostring = tostring
local pairs = pairs
local ipairs = ipairs
local type = type
local setmetatable = setmetatable
local os = os
local string = string
local math = math
local var_dump = require("aspect.utils").var_dump
local month = require("aspect.config").date.months
local current_offset = (os.time() - os.time(os.date("!*t", os.time())))

--- Merge table `b` into table `a`
local function union(a,b)
    for k,x in pairs(b) do
        a[k] = x
    end
    return a
end

local function ctime(d, m, y)
    m = string.lower(m)
    if not month[m] then
        return nil
    end
    return {
        year = tonumber(y) or tonumber(os.date("%Y")) or 1970,
        month = month[m],
        day = tonumber(d)
    }
end

--- How to works parsers
--- 1. take `date` parser.
--- 1.1 Iterate by patterns.
--- 1.2 When pattern matched then `match` function will be called.
--- 1.3 `Match` function returns table like os.date("*t") if success, nil if failed (if nil resume 1.1)
--- 2. take `time` parser. search continues with the next character after matched `date`
--- 2.1 Iterate by patterns.
--- 2.2 When pattern matched then `match` function will be called.
--- 2.3 `Match` function returns table like os.date("*t") if success, nil if failed (if nil resume 2.1)
--- 3. take `zone` parser. search continues with the next character after matched `time`
--- 2.1 Iterate by patterns.
--- 2.2 When pattern matched then `match` function will be called.
--- 2.3 `Match` function returns table like os.date("*t") if success, nil if failed (if nil resume 3.1)
--- 4. calculate timestamp
local parsers = {
    date = {
        -- 2020-12-02, 2020.12.02
        {
            pattern = "(%d%d%d%d)[.%-](%d%d)[.%-](%d%d)",
            match = function(y, m , d)
                return {year = tonumber(y), month = tonumber(m), day = tonumber(d)}
            end
        } ,
        -- 02-12-2020, 02.12.2020
        {
            pattern = "(%d%d)[.%-](%d%d)[.%-](%d%d%d%d)",
            match = function(y, m , d)
                return {
                    year = tonumber(y),
                    month = tonumber(m),
                    day = tonumber(d)
                }
            end
        },
        -- ctime: Jan 14 2020, January 14 2020
        {
            pattern = "(%d%d)[%s-]+(%a%a+)[%s-]+(%d%d%d%d)",
            match = function(d, m, y)
                return ctime(d, m, y)
            end
        },
        -- ctime: Jan 14, January 14
        {
            pattern = "(%d%d)[%s-]+(%a%a+)",
            match = function(d, m)
                return ctime(d, m)
            end
        },
        -- rfc 1123: 14 Jan 2020, 14 January 2020
        {
            pattern = "(%a%a+)%s+(%d%d)%s+(%d%d%d%d)",
            match = function(m, d, y)
                return ctime(d, m, y)
            end
        },
        -- rfc 1123: 14 Jan, 14 January
        {
            pattern = "(%a%a+)%s+(%d%d)",
            match = function(m, d)
                return ctime(d, m)
            end
        },
        -- US format MM/DD/YYYY: 12/23/2020
        {
            pattern = "(%d%d)/(%d%d)/(%d%d%d%d)",
            match = function(m, d, y)
                return {
                    year = tonumber(y),
                    month = tonumber(m),
                    day = tonumber(d)
                }
            end
        },
        {
            pattern = "(%d%d)/(%d%d)/(%d%d%d%d)",
            match = function(m, d, y)
                return {
                    year = tonumber(y),
                    month = tonumber(m),
                    day = tonumber(d)
                }
            end
        }
    },
    time = {
        {
            pattern = "(%d%d):(%d%d):?(%d?%d?)",
            match = function(h, m, s)
                return {
                    hour = tonumber(h),
                    min = tonumber(m),
                    sec = tonumber(s) or 0
                }
            end
        }
    },
    zone = {
        -- +03:00, -11, +3:30
        {
            pattern = "([+-])(%d?%d):?(%d?%d?)",
            match = function (mod, h, m)
                local sign = (mod == "-") and -1 or 1
                return {
                    offset = sign * (tonumber(h) * 60 + (tonumber(m) or 0)) * 60
                }
            end
        },
        -- UTC marker
        {
            pattern = "UTC",
            match = function ()
                return {offset = 0}
            end
        },
        -- GMT marker
        {
            pattern = "GMT",
            match = function ()
                return {offset = 0}
            end
        }
    }
}

--- Parse about any textual datetime description into a Unix timestamp
--- @param t string
--- @return number UTC timestamp
--- @return table datetime description: year, month, day, hour, min, sec, ...
local function strtotime(t)
    local from = 1
    local time = {day = 1, month = 1, year = 1970}
    for _, parser in ipairs({parsers.date, parsers.time, parsers.zone}) do
        for _, matcher in ipairs(parser) do
            local i, j = string.find(t, matcher.pattern, from)
            if i then
                --var_dump("Found by pattern " .. matcher.pattern .. ": " .. string.sub(t, i, j))
                local res = matcher.match(string.sub(t, i, j):match("^" .. matcher.pattern .. "$"))
                if res then
                    union(time, res)
                    from = j + 1
                    break
                end
            end
        end
    end
    local ts = os.time(time) -- ts
    if not time.offset then -- no offset parsed - use local offset
        time.offset = current_offset
    else
        ts = ts - (time.offset - current_offset)
    end
    return ts, time
end

--- @class aspect.utils.date
--- @param time number it is timestamp, all dates formats to timestamp
--- @param offset number UTC time offset (timezone) In minutes!
local date = {
    _NAME = "aspect.date",

    strtotime    = strtotime,
    parsers      = parsers,
    local_offset = current_offset,
}

function date:format(format)
    local utc = false
    local time = self.time
    local offset = self.offset
    if format:sub(1, 1) == "!" then
        utc = true
    end
    if utc and string.find(format, "%%z") then
        format = string.gsub(format, "%%z", self:getTimezone(""))
    end
    return os.date(format, time)
end

--- Returns offset as time zone
--- @return string like +03:00
function date:getTimezone(delim)
    delim = delim or ":"
    local sign = (self.offset < 0) and '-' or '+'
    if self.offset == 0 then
        return sign .. "00"
    end
    local m = math.abs((self.offset / 60) % 60)
    local h = m / 60

    return string.format(sign .. "%02d" .. delim .. "%02d", h, m)
end

--- @return string
function date:__tostring()
    return os.date("%F %T " .. self.offset, self.time + self.offset)
end

--- @param b any
--- @return string
function date:__concat(b)
    return tostring(self) .. tostring(b)
end

--- @param b any
--- @return aspect.utils.date
function date:__add(b)
    return date.new(self.time + date.new(b).time, self.offset)
end

--- @param b any
--- @return aspect.utils.date
function date:__sub(b)
    return date.new(self.time - date.new(b).time, self.offset)
end

--- @param b number
--- @return aspect.utils.date
function date:__mul(b)
    if type(b) == "number" and b > 0 then
        return date.new(self.time * b, self.offset)
    else
        return self
    end
end

--- @param b number
--- @return aspect.utils.date
function date:__div(b)
    if type(b) == "number" and b > 0 then
        return date.new(self.time / b, self.offset)
    else
        return self
    end
end

function date:__eq(b)
    return self.time == date.new(b).time
end

--- @param b any
--- @return boolean
function date:__lt(b)
    return self.time < date.new(b).time
end

--- @param b any
--- @return boolean
function date:__le(b)
    return self.time <= date.new(b).time
end

local date_mods = {
    seconds = "sec",
    second  = "sec",
    secs    = "sec",
    sec     = "sec",
    minutes = "min",
    minute  = "min",
    mins    = "min",
    min     = "min",
    hours   = "hour",
    hour    = "hour",
    days    = "day",
    day     = "day",
    months  = "month",
    month   = "month",
    years   = "year",
    year    = "year",
}

function date:modify(t)
    local d = os.date("*t", self.time)
    for k, v in pairs(t) do
        if date_mods[k] then
            local name = date_mods[k]
            d[name] = d[name] + v
        end
        --var_dump("date:modify", self.info, self.time, d)
    end
    self.time = os.time(d)
    return self
end


local mt = {
    __index = date,
    __tostring = date.__tostring,
    __add = date.__add,
    __sub = date.__sub,
    __mul = date.__mul,
    __div = date.__div,
    __eq = date.__eq,
    __lt = date.__lt,
    __le = date.__le,
}


function date.new(t, offset)
    local typ, time, info = type(t), 0, {}
    offset = offset or 0
    if typ == "number" then
        time = t
    elseif typ == "table" then
        if t._NAME == date._NAME then
            return t
        else
            local _t = {year = 1970, month = 1, day = 1}
            union(_t, t)
            time = os.time(_t)
        end
    elseif typ == "string" or typ == "userdata" then
        time, info = strtotime(tostring(t))
        offset = info.offset
    else
        time = os.time()
    end

    return setmetatable({
        time = time,
        offset = offset,
        info = info
    }, mt)
end

return date