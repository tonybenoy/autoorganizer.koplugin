-- Pure string logic (no KOReader dependencies) so it can be unit tested with plain Lua.
local Core = {}

Core.EXTS = {
    epub = true, pdf = true, mobi = true, azw = true, azw3 = true,
    fb2 = true, djvu = true, cbz = true, kepub = true,
}

-- Folder names/paths never scanned unless you remove them from the exclude list.
-- (Hidden folders, .sdr folders are always skipped.)
Core.DEFAULT_EXCLUDES = {
    "koreader", "extensions", "system", "audible", "linkfonts", "linkss",
    "mrpackages", "usbnet", "Android", "fonts",
}

Core.DEFAULTS = {
    series_template = "{author}/{series}/{index} - {title}",
    single_template = "{author}/{title}",
    author_format = "last_first", -- "last_first" | "first_last"
    index_pad = 2,
}

-- Minimum confidence for moving a book without asking the internet.
Core.ACCEPT = 0.75

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
Core.trim = trim

local function words(s)
    local t = {}
    for w in s:gmatch("%S+") do t[#t + 1] = w end
    return t
end

function Core.get_ext(path)
    local ext = path:match("%.([%w]+)$")
    return ext and ext:lower() or nil
end

function Core.is_book(path)
    local ext = Core.get_ext(path)
    return ext ~= nil and Core.EXTS[ext] == true
end

function Core.basename(path)
    return path:match("([^/]+)$") or path
end

function Core.dirname(path)
    return path:match("^(.*)/[^/]*$") or "."
end

---------------------------------------------------------------------------
-- Scan scope: include / exclude rules
---------------------------------------------------------------------------

-- Best guess at "the whole device" for the storage the library lives on.
function Core.default_scan_root(home)
    for _, r in ipairs{ "/mnt/us", "/mnt/onboard", "/mnt/ext1", "/mnt/sd", "/sdcard", "/storage/emulated/0" } do
        if home and (home == r or home:sub(1, #r + 1) == r .. "/") then return r end
    end
    return home
end

local function glob_to_pattern(g)
    local p = g:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
    p = p:gsub("%*", ".*")
    return "^" .. p .. "$"
end

-- A rule is either an absolute path/glob ("/mnt/us/documents/Comics", "/mnt/us/doc*/old")
-- matching that folder and everything inside it, or a bare name/glob ("Downloads", "*.old")
-- matching any folder with that name at any depth.
function Core.rule_matches(rule, path)
    rule = trim(rule)
    if rule == "" then return false end
    if rule:sub(1, 1) == "/" then
        local pat = glob_to_pattern((rule:gsub("/+$", "")))
        local cur = path
        while cur ~= "" do
            if cur:match(pat) then return true end
            cur = cur:match("^(.*)/[^/]*$") or ""
        end
        return false
    end
    local pat = glob_to_pattern(rule)
    for seg in path:gmatch("[^/]+") do
        if seg:match(pat) then return true end
    end
    return false
end

local function any_rule(rules, path)
    for _, r in ipairs(rules or {}) do
        if Core.rule_matches(r, path) then return true end
    end
    return false
end

-- Is `path` inside what the include rules allow? Empty include list = everything.
-- For directories, also true when an include rule lives *below* it (so we can reach it).
function Core.included(includes, path, is_dir)
    if not includes or #includes == 0 then return true end
    if any_rule(includes, path) then return true end
    if is_dir then
        for _, r in ipairs(includes) do
            r = trim(r)
            if r:sub(1, 1) ~= "/" then return true end -- bare names can be anywhere
            local literal = r:match("^([^*]*)")
            if literal:sub(1, #path + 1) == path .. "/" or literal == path then return true end
        end
    end
    return false
end

function Core.excluded(excludes, path)
    return any_rule(excludes, path)
end

---------------------------------------------------------------------------
-- Cleaning / author handling
---------------------------------------------------------------------------

-- Make a single path segment safe on FAT/exFAT/NTFS as well as ext4.
function Core.sanitize(s)
    if not s then return "" end
    s = s:gsub("[%c]", " ")
    s = s:gsub('[/\\:%*%?"<>|]', " ")
    s = s:gsub("%s+", " ")
    s = trim(s)
    s = s:gsub("[%. ]+$", "") -- no trailing dots/spaces
    s = s:gsub("^%.+", "")    -- no hidden files
    if #s > 100 then s = trim(s:sub(1, 100)) end
    return s
end

local JUNK = { unknown = true, ["unknown author"] = true, ["unknown title"] = true,
    untitled = true, ["n/a"] = true, none = true, [""] = true, anonymous = true }

local function clean_field(s)
    if type(s) ~= "string" then return nil end
    s = trim(s)
    if JUNK[s:lower()] then return nil end
    return s
end
Core.clean_field = clean_field

-- Placeholder titles that editors/converters leave behind.
function Core.is_junk_title(t)
    if not clean_field(t) then return true end
    local l = t:lower()
    return l:match("^new title") ~= nil or l:match("^untitled") ~= nil
        or l:match("^document%s*%d*$") ~= nil or l:match("^microsoft word") ~= nil
end

local SUFFIXES = { jr = true, ["jr."] = true, sr = true, ["sr."] = true,
    ii = true, iii = true, iv = true }

-- Order-independent key so "Herbert, Frank" == "Frank Herbert" == "frank  herbert".
function Core.author_key(s)
    s = (s or ""):lower():gsub("%.", " "):gsub("[^%w%s]", " ")
    local t = words(s)
    table.sort(t)
    return table.concat(t, " ")
end

-- Takes an authors string (may be "A\nB", "A & B", "A; B", "A and B") and returns the
-- primary author in the requested format.
function Core.normalize_author(raw, format)
    raw = clean_field(raw)
    if not raw then return nil end
    local first = raw:match("^([^\n]+)") or raw
    first = first:match("^(.-)%s+&%s+") or first
    first = first:match("^(.-)%s+and%s+%u") or first
    first = first:match("^(.-);") or first
    first = first:match("^(.-):%s") or first
    first = clean_field(first)
    if not first then return nil end
    if first:find(",", 1, true) then
        if format == "first_last" then
            local last, rest = first:match("^(.-)%s*,%s*(.+)$")
            if last and rest then return rest .. " " .. last end
        end
        return first
    end
    if format ~= "last_first" then return first end
    local tokens = words(first)
    if #tokens < 2 then return first end
    local last = table.remove(tokens)
    if SUFFIXES[last:lower()] and #tokens >= 2 then
        last = table.remove(tokens) .. " " .. last
    end
    return last .. ", " .. table.concat(tokens, " ")
end

---------------------------------------------------------------------------
-- "Does this text look like a person's name?"
---------------------------------------------------------------------------

local FIRST_NAMES = {}
for n in ([[
adam adrian alan albert alex alexander alice amanda amy andrew andy angela ann anna anne anthony arthur
barbara ben benjamin bill billy bob brandon brian bruce carl carol caroline catherine charles charlie
chris christopher claire colin craig dan daniel dave david dean dennis diana diane donald douglas
dorothy edward elizabeth ellen emily emma eric ernest eugene frances francis frank fred frederick gary
gavin george gerald gillian gordon graham greg gregory hannah harold harper harry helen henry herbert
howard hugh ian isaac isaiah jack jacob james jamie jane janet jason jean jeff jeffrey jennifer jeremy
jerry jessica jim jimmy joan joe joel john jon jonathan joseph josh joshua joy judith julia julian
karen kate katherine kathleen keith kelly ken kenneth kevin kim larry laura lauren lawrence lee leo
leonard lewis linda lisa liz louis lucy luke margaret maria marie mark martin mary matt matthew max
megan melissa michael michelle mike neal neil neville nicholas nick nicole noah norman oliver oscar
patricia patrick paul peter philip phil rachel ralph randall ray raymond rebecca richard rick ricky
robert robin roger ron ronald rose ruth ryan sam samuel sandra sarah scott sean sharon simon sophie
stephen steve steven stuart sue susan suzanne sylvia ted terry thomas tim timothy tom tony tracy
trevor ursula valerie vera veronica victor victoria vincent virginia walter wayne william yvonne
zoe stanislaw isaac arthur yuval neil carlo daniel kazuo haruki murakami agatha stieg tamora
]]):gmatch("%a+") do FIRST_NAMES[n] = true end

local PARTICLES = { van = true, von = true, de = true, der = true, den = true, la = true, le = true,
    di = true, da = true, del = true, bin = true, al = true, el = true, du = true, ten = true, mc = true }
local STOP = { the = true, of = true, ["and"] = true, ["in"] = true, to = true, ["for"] = true,
    a = true, an = true, on = true, at = true, with = true, from = true, by = true, is = true,
    are = true, why = true, how = true, what = true, who = true, ["not"] = true, vs = true }
local ARTICLES = { the = true, a = true, an = true }

-- 0..1: how much `s` looks like an author name. `known` is a set of author_key()s.
function Core.score_author(s, known)
    s = trim(s or "")
    if s == "" or s:find("%d") then return 0 end
    if known and known[Core.author_key(s)] then return 1 end

    local last, rest = s:match("^([^,]+),%s*(.+)$")
    if last and rest then
        local r = rest:lower():gsub("%.", "")
        if ARTICLES[r] then return 0 end -- "Feast for Crows, A"
        if #words(last) <= 3 and #words(rest) <= 3 then return 0.9 end
        return 0.2
    end

    local ws = words(s)
    local n = #ws
    if n == 0 or n > 5 then return 0.1 end
    local score = (n == 1) and 0.3 or (n <= 4 and 0.55 or 0.3)
    local stops, lowers, initials = 0, 0, 0
    for i, w in ipairs(ws) do
        local lw = w:lower():gsub("[%.,]", "")
        if STOP[lw] then stops = stops + 1
        elseif not PARTICLES[lw] and w:match("^%l") then lowers = lowers + 1 end
        if w:match("^%u%.?$") or w:match("^%u%.%u%.?$") then initials = initials + 1 end
    end
    if stops > 0 then score = score - 0.35 end
    if lowers > 0 then score = score - 0.2 end
    if initials > 0 then score = score + 0.15 end
    local fw = ws[1]:lower():gsub("[%.,]", "")
    if FIRST_NAMES[fw] then score = score + 0.35 end
    if score < 0 then score = 0 elseif score > 1 then score = 1 end
    return score
end

-- Decide which of a, b is the author. Returns author, title, confidence — or nil if unclear.
function Core.orient(a, b, known)
    local sa, sb = Core.score_author(a, known), Core.score_author(b, known)
    local diff = math.abs(sa - sb)
    if diff < 0.25 then return nil end
    local conf = math.min(0.95, 0.5 + diff)
    if sa > sb then return a, b, conf end
    return b, a, conf
end

---------------------------------------------------------------------------
-- Filename understanding
---------------------------------------------------------------------------

local function to_index(s) return tonumber(s) end

local SERIES_PATS = {
    "^(.-),%s*[Bb]oo?k%s*#?(%d+%.?%d*)$",
    "^(.-)%s+[Bb]oo?k%s*#?(%d+%.?%d*)$",
    "^(.-),%s*[Vv]olume%s*(%d+)$",
    "^(.-)%s+[Vv]olume%s*(%d+)$",
    "^(.-),%s*[Vv]ol%.?%s*(%d+)$",
    "^(.-)%s+[Vv]ol%.?%s*(%d+)$",
    "^(.-),%s*#(%d+%.?%d*)$",
    "^(.-)%s+#(%d+%.?%d*)$",
    "^(.-)%-(%d+)$",              -- asoiaf-4
    "^(.-),%s*(%d+%.?%d*)$",      -- Series, 3
}

local function match_series(g)
    g = trim(g)
    for _, p in ipairs(SERIES_PATS) do
        local s, n = g:match(p)
        if s and trim(s) ~= "" then return trim(s), to_index(n) end
    end
end

local JUNK_PATS = { "z%-?lib", "libgen", "pdfdrive", "anna.-archive", "epublibre", "edition", "unabridged", "dokumen", "isbn",
    "oceanofpdf", "ebook", "retail", "www%.", "%.com", "%.org", "^epub$", "^mobi$", "^azw3?$",
    "^%d%d%d%d$", "^%d%d%d%d%-%d%d%-%d%d$" }

local function is_junk_text(g)
    local l = trim(g):lower()
    if l == "" then return true end
    if #l >= 16 and l:match("^%x+$") then return true end -- md5-style hash
    for _, p in ipairs(JUNK_PATS) do
        if l:find(p) then return true end
    end
    return false
end

-- Remove "(Series, Book 3)", "(A Foo Novel)", junk groups. Returns title, series, index.
local function extract_series(title)
    local series, index
    local function handle(g)
        if is_junk_text(g) then return "" end
        local s, n = match_series(g)
        if s and not series then series, index = s, n; return "" end
        local nov = g:match("^[Aa]n?%s+(.-)%s+[Nn]ovel$")
        if nov and trim(nov) ~= "" then
            if not series then series = trim(nov) end
            return ""
        end
        return nil
    end
    title = title:gsub("%s*%(([^()]*)%)", handle)
    title = title:gsub("%s*%[([^%[%]]*)%]", handle)
    return trim(title), series, index
end

-- "Feast for Crows, A" -> "A Feast for Crows"; drop " A Novel" / trailing dashes.
local function clean_title(t)
    t = trim(t)
    t = t:gsub("%s*%([^()]*$", "")  -- unbalanced "(" left by a truncated filename
    t = t:gsub("^[%-%s]+", ""):gsub("[%-%s]+$", "")
    local body, art = t:match("^(.-)%s*,%s*([TtAa][Hh]?[Ee]?[Nn]?)$")
    if body and ARTICLES[art:lower()] then t = art .. " " .. body end
    t = t:gsub("%s+[Aa]%s+[Nn]ovel$", "")
    return trim(t)
end

local function split_on(s, sep)
    local out, pos = {}, 1
    while true do
        local i, j = s:find(sep, pos, true)
        if not i then out[#out + 1] = s:sub(pos); break end
        out[#out + 1] = s:sub(pos, i - 1)
        pos = j + 1
    end
    for i, v in ipairs(out) do out[i] = trim(v) end
    return out
end

local function normalize_name(path)
    local name = Core.basename(path):gsub("%.[%w]+$", "")
    name = name:gsub("(%f[%w]%u)_%.?", "%1.")  -- "George R_ R_ Martin" -> "George R. R. Martin"
    name = name:gsub("_+%s", ": "):gsub("_", " ")
    name = name:gsub("[Pp][Dd][Ff][Dd]rive%.com", ""):gsub("[Dd]okumen%.pub[ _%-]*", "")
    name = name:gsub("[Zz]%-[Ll]ib%.org", ""):gsub("[Ll]ib[Gg]en%.%a+", "")
    name = name:gsub("%s+", " ")
    name = name:gsub("%s+%-%s+%-%s+", " - ")      -- "A - - B" left behind by removals
    return trim(name)
end

-- Understand a filename. Returns a table with any of:
--   title, author, series, index   — what we worked out
--   conf                           — 0..1 confidence in the author/title split
--   pair                           — {left, right} when "X - Y" could not be oriented
--   why                            — short human-readable explanation
function Core.parse_name(path, known)
    local name = normalize_name(path)
    local out = { why = "filename" }

    -- "Series [2]-Title ..."
    local s0, i0, rest = name:match("^(.-)%s*%[(%d+%.?%d*)%]%s*%-%s*(.+)$")
    if s0 and trim(s0) ~= "" then
        out.series, out.index, name = trim(s0), to_index(i0), trim(rest)
    end

    local function finish_title(t, explicit_author)
        if out.author then
            out.author = trim((out.author:gsub("%s*[%[%(].*$", "")))
            -- truncated filenames repeat the author ("Suzanne Collins Collins Suzanne")
            local seen, kept = {}, {}
            for _, w in ipairs(words(out.author)) do
                local lw = w:lower():gsub("[%.,:;_]", "")
                if #lw > 2 and seen[lw] then break end
                seen[lw] = true
                kept[#kept + 1] = w
            end
            out.author = table.concat(kept, " ")
        end
        local title, series, index = extract_series(t)
        if series and not out.series then out.series, out.index = series, index end
        if explicit_author and not out.series then
            -- "Hunger Games 2 - Catching Fire"
            local sp, n, tt = title:match("^(.-)%s+(%d%d?%.?%d*)%s+%-%s+(.+)$")
            if sp and trim(sp) ~= "" then out.series, out.index, title = trim(sp), to_index(n), tt end
        end
        out.title = clean_title(title)
    end

    -- Anna's-Archive style: "Title -- Author -- Series, N -- Year -- Publisher -- hash"
    local segs = split_on(name, " -- ")
    if #segs >= 2 then
        local t, a = segs[1], segs[2]
        local author, title, conf = Core.orient(a, t, known) -- prefer reading it as Title -- Author
        if author == t then t, a = a, t end                  -- the file is Author -- Title
        out.author = a
        out.conf = conf and math.max(conf, 0.8) or 0.8
        out.why = "filename (title -- author)"
        finish_title(t, true)
        if segs[3] and not is_junk_text(segs[3]) and not out.series then
            local s, n = segs[3]:match("^(.-)[,%s]+#?(%d%d?%.?%d*)")
            if s and trim(s) ~= "" and not s:match("^%d") then
                out.series, out.index = trim(s), to_index(n)
            end
        end
        return out
    end

    local parts = split_on(name, " - ")
    if #parts == 1 then
        finish_title(name, false)
        out.conf = 0.3 -- title only, no author
        return out
    end

    if #parts == 3 then
        -- "Author - Series 03 - Title"
        local sname, n = parts[2]:match("^(.-)%s+#?(%d%d?%.?%d*)$")
        if sname and trim(sname) ~= "" then
            local author, title, conf = Core.orient(parts[1], parts[3], known)
            if author then
                out.author, out.series, out.index = author, trim(sname), to_index(n)
                out.conf, out.why = conf, "filename (author - series N - title)"
                finish_title(title, true)
                return out
            end
        end
    end

    if #parts == 2 then
        local author, title, conf = Core.orient(parts[1], parts[2], known)
        if author then
            out.author, out.conf = author, conf
            out.why = "filename (name shape)"
            finish_title(title, true)
            return out
        end
        out.pair = { parts[1], parts[2] }
        out.conf = 0.3
        out.why = "filename (can't tell which side is the author)"
        finish_title(name, false)
        out.title = nil
        return out
    end

    finish_title(name, false)
    out.conf = 0.2
    out.why = "filename (too many parts)"
    out.title = nil
    return out
end

---------------------------------------------------------------------------
-- Combine embedded metadata with the filename
---------------------------------------------------------------------------

-- Returns fields {title, author, series, index}, confidence (0..1), why, pair.
function Core.identify(path, embedded, known, format)
    embedded = embedded or {}
    local g = Core.parse_name(path, known)
    local fname = Core.basename(path):gsub("%.[%w]+$", "")

    local etitle = clean_field(embedded.title)
    if etitle and (Core.is_junk_title(etitle) or etitle == fname) then etitle = nil end
    local eauthor = Core.normalize_author(embedded.author, format)

    local f = {}
    local conf, why
    if etitle and eauthor then
        f.title, f.author, conf, why = etitle, eauthor, 1, "embedded tags"
        f.series = clean_field(embedded.series) or g.series
        f.index = tonumber(embedded.index) or (f.series and g.index) or nil
    else
        f.series = clean_field(embedded.series) or g.series
        f.index = tonumber(embedded.index) or g.index
        f.title, f.author = etitle or g.title, eauthor or Core.normalize_author(g.author, format)
        conf, why = g.conf or 0.3, g.why
        local pair = g.pair
        if pair and (etitle or eauthor) then
            -- the tags tell us which side is which
            local l, r = pair[1], pair[2]
            local ref = eauthor or etitle
            local sl, sr = Core.similarity(l, ref), Core.similarity(r, ref)
            if math.abs(sl - sr) >= 0.3 then
                local match_left = sl > sr
                if eauthor then f.title = match_left and r or l
                else f.author = Core.normalize_author(match_left and r or l, format) end
                local t, s, i = extract_series(f.title)
                f.title = clean_title(t)
                if s and not f.series then f.series, f.index = s, i end
                conf, why, pair = 0.9, "filename + tags", nil
            end
        end
        if etitle or eauthor then conf = math.max(conf, 0.5) end
        g.pair = pair
    end
    -- embedded titles like "Divergent - Veronica Roth": drop the trailing author
    if f.title and f.author then
        local head, tail = f.title:match("^(.-)%s+%-%s+([^%-]+)$")
        if head and clean_field(head) and Core.similarity(tail, f.author) >= 0.5 then
            f.title = trim(head)
        end
    end
    if f.series and f.title and f.series:lower() == f.title:lower() and not f.index then f.series = nil end
    if f.index and f.index <= 0 then f.index = nil end
    if f.title then f.title = clean_title(f.title) end
    if Core.is_junk_title(f.title) then f.title = nil end
    if not (f.title and f.author) then conf = math.min(conf, 0.4) end
    return f, conf, why, g.pair
end

function Core.format_index(n, pad)
    if not n then return "" end
    pad = pad or 2
    local whole = math.floor(n)
    local s = string.format("%0" .. pad .. "d", whole)
    local frac = n - whole
    if frac > 1e-6 then
        local d = string.format("%.2f", frac):sub(2):gsub("0+$", "")
        s = s .. d
    end
    return s
end

function Core.is_complete(f)
    return f.title ~= nil and f.author ~= nil
end

-- Returns a relative path ("Author/Series/01 - Title.epub") or nil if incomplete.
function Core.render(f, ext, cfg)
    cfg = cfg or Core.DEFAULTS
    if not Core.is_complete(f) then return nil end
    local tpl
    if f.series and f.index then
        tpl = cfg.series_template or Core.DEFAULTS.series_template
    elseif f.series then
        tpl = "{author}/{series}/{title}"
    else
        tpl = cfg.single_template or Core.DEFAULTS.single_template
    end
    local vals = {
        author = f.author, series = f.series or "", title = f.title,
        index = Core.format_index(f.index, cfg.index_pad),
    }
    local rendered = tpl:gsub("{(%w+)}", function(k) return vals[k] or "" end)
    local parts = {}
    for seg in rendered:gmatch("[^/]+") do
        seg = Core.sanitize(seg)
        if seg ~= "" then parts[#parts + 1] = seg end
    end
    if #parts == 0 then return nil end
    parts[#parts] = parts[#parts] .. "." .. ext
    return table.concat(parts, "/")
end

-- Word-overlap similarity (0..1), for validating online lookup results.
local function tokens(s)
    local set, n = {}, 0
    for w in (s or ""):lower():gmatch("%w+") do
        if not set[w] then set[w] = true; n = n + 1 end
    end
    return set, n
end

function Core.similarity(a, b)
    local sa, na = tokens(a)
    local sb, nb = tokens(b)
    if na == 0 or nb == 0 then return 0 end
    local inter = 0
    for w in pairs(sa) do if sb[w] then inter = inter + 1 end end
    return inter / (na + nb - inter)
end

return Core
