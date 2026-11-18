-- Metadata sources: embedded (via KOReader's document engines) and online (Open Library).
local Core = require("autoorganizer_core")

local Meta = {}

-- Reads title/author/series from the book itself (epub, fb2, mobi, pdf, ...).
-- Calibre-style series tags are exposed by crengine as props.series / series_index.
function Meta.embedded(path)
    local ok, result = pcall(function()
        local DocumentRegistry = require("document/documentregistry")
        if not DocumentRegistry:hasProvider(path) then return nil end
        local doc = DocumentRegistry:openDocument(path)
        if not doc then return nil end
        local props = doc:getProps() or {}
        pcall(doc.close, doc)
        return {
            title = props.title,
            author = props.authors,
            series = props.series,
            index = props.series_index,
        }
    end)
    if ok then return result end
    return nil
end

local function http_get_json(url)
    local ok, data = pcall(function()
        local https = require("ssl.https")
        local ltn12 = require("ltn12")
        local socketutil = require("socketutil")
        local json = require("json")
        local socket = require("socket")
        local sink = {}
        socketutil:set_timeout(5, 15)
        local code = socket.skip(1, https.request{
            url = url,
            method = "GET",
            headers = { ["User-Agent"] = "KOReader-AutoOrganizer-plugin" },
            sink = socketutil.table_sink(sink),
        })
        socketutil:reset_timeout()
        if code ~= 200 then return nil end
        return json.decode(table.concat(sink))
    end)
    if ok then return data end
    return nil
end

local function urlencode(s)
    return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Looks the book up on Open Library by title (+ author if known). Only returns a
-- result when the title matches closely, so wrong guesses end up in review instead.
-- Fills in author and canonical title; Open Library does not reliably expose series.
function Meta.online(fields)
    if not fields.title then return nil end
    local url = "https://openlibrary.org/search.json?limit=5&fields=title,author_name"
        .. "&title=" .. urlencode(fields.title)
    if fields.author then
        local a = fields.author:gsub(",.*$", "")
        url = url .. "&author=" .. urlencode(a)
    end
    local data = http_get_json(url)
    if not data or type(data.docs) ~= "table" then return nil end
    local best, best_score
    for _, d in ipairs(data.docs) do
        if d.title and d.author_name and d.author_name[1] then
            local score = Core.similarity(fields.title, d.title)
            if not best_score or score > best_score then best, best_score = d, score end
        end
    end
    if best and best_score >= 0.8 then
        return { title = best.title, author = best.author_name[1] }
    end
    return nil
end

-- Decide which side of "X - Y" is the author by asking Open Library. Returns
-- {title=, author=} only if one orientation is confirmed (title AND author both match).
function Meta.resolve_pair(left, right)
    for _, o in ipairs({ { left, right }, { right, left } }) do
        local found = Meta.online({ title = o[1], author = o[2] })
        if found and Core.similarity(o[1], found.title) >= 0.8
            and Core.similarity(o[2], found.author) >= 0.5 then
            return { title = o[1], author = o[2] }
        end
    end
    return nil
end

return Meta
