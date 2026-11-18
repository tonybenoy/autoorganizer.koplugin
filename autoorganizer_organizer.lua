-- Scans folders, decides where each book belongs, moves it (with its reading
-- progress), and keeps an undo log. Runs one book per UI tick so the device stays responsive.
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local Core = require("autoorganizer_core")
local Meta = require("autoorganizer_meta")

local Organizer = {}
Organizer.__index = Organizer

function Organizer:new(settings)
    local o = setmetatable({}, self)
    o.settings = settings -- function returning the current config table
    o.state = LuaSettings:open(DataStorage:getSettingsDir() .. "/autoorganizer_state.lua")
    o.running = false
    return o
end

local function exists(p) return lfs.attributes(p, "mode") ~= nil end

local function mkdirs(path)
    local cur = path:sub(1, 1) == "/" and "" or "."
    for seg in path:gmatch("[^/]+") do
        cur = cur .. "/" .. seg
        if not exists(cur) then
            local ok, err = lfs.mkdir(cur)
            if not ok then return false, err end
        end
    end
    return true
end

local function signature(path)
    local a = lfs.attributes(path)
    if not a then return nil end
    return a.size .. ":" .. a.modification
end

-- Recursively collect book files under dir, honouring include/exclude rules.
local function collect(dir, cfg, out)
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return out end
    for name in iter, dir_obj do
        if name:sub(1, 1) ~= "." then
            local full = dir .. "/" .. name
            local mode = lfs.attributes(full, "mode")
            if mode == "directory" then
                if not name:find("%.sdr$")
                    and not Core.excluded(cfg.excludes, full)
                    and Core.included(cfg.includes, full, true) then
                    collect(full, cfg, out)
                end
            elseif mode == "file" and Core.is_book(full)
                and not Core.excluded(cfg.excludes, full)
                and Core.included(cfg.includes, full, false) then
                out[#out + 1] = full
            end
        end
    end
    return out
end

local function unique_target(target, source)
    if target == source or not exists(target) then return target end
    local base, ext = target:match("^(.*)%.([%w]+)$")
    for n = 2, 99 do
        local candidate = string.format("%s (%d).%s", base, n, ext)
        if candidate == source or not exists(candidate) then return candidate end
    end
    return nil
end

local function remove_empty_dirs(dir, stop_at)
    while dir and dir ~= stop_at and #dir > #stop_at do
        local empty = true
        local ok, iter, d = pcall(lfs.dir, dir)
        if not ok then return end
        for n in iter, d do
            if n ~= "." and n ~= ".." then empty = false break end
        end
        if not empty or not lfs.rmdir(dir) then return end
        dir = Core.dirname(dir)
    end
end

local function move_file(from, to)
    if os.rename(from, to) then return true end
    -- different filesystem: copy then delete
    local ok = pcall(function()
        require("ffi/util").copyFile(from, to)
    end)
    if ok and exists(to) then
        os.remove(from)
        return true
    end
    return false
end

-- Carry reading progress/bookmarks/history along with the book.
local function move_metadata(from, to)
    local moved = false
    pcall(function()
        local DocSettings = require("docsettings")
        if DocSettings.updateLocation then
            DocSettings.updateLocation(from, to)
            moved = true
        end
    end)
    if not moved then
        pcall(function()
            local DocSettings = require("docsettings")
            local old_sdr = DocSettings:getSidecarDir(from)
            local new_sdr = DocSettings:getSidecarDir(to)
            if exists(old_sdr) and not exists(new_sdr) then os.rename(old_sdr, new_sdr) end
        end)
    end
    pcall(function()
        require("readhistory"):updateItemByPath(from, to)
    end)
end

-- Folders that get scanned: the configured scan roots, plus the library folder itself.
local function scan_roots(cfg)
    local roots = {}
    for _, r in ipairs(cfg.scan_roots or {}) do
        if exists(r) then roots[#roots + 1] = (r:gsub("/+$", "")) end
    end
    local lib = cfg.library_root
    local covered = false
    for _, r in ipairs(roots) do
        if lib == r or lib:sub(1, #r + 1) == r .. "/" then covered = true end
    end
    if not covered then roots[#roots + 1] = lib end
    return roots
end

-- Work out what we'd do with one file. Returns
--   { from, to, fields, status, why }   status: "ok" | "same" | "review"
-- `embedded` may be passed in to avoid re-reading the book.
function Organizer:plan_one(path, cfg, known, online, embedded)
    embedded = embedded or Meta.embedded(path) or false
    local fields, conf, why, pair = Core.identify(path, embedded, known, cfg.author_format)

    if conf < Core.ACCEPT and online and cfg.online_lookup then
        local NetworkMgr = require("ui/network/manager")
        if NetworkMgr:isOnline() then
            if pair then
                local found = Meta.resolve_pair(pair[1], pair[2])
                if found then
                    fields.title = found.title
                    fields.author = Core.normalize_author(found.author, cfg.author_format)
                    conf, why = 0.9, "online lookup (confirmed which side is the author)"
                end
            elseif fields.title and not fields.author then
                local found = Meta.online(fields)
                if found then
                    fields.author = Core.normalize_author(found.author, cfg.author_format)
                    conf, why = 0.85, "online lookup (author)"
                end
            end
        end
    end

    local ext = Core.get_ext(path)
    local rel = (conf >= Core.ACCEPT) and Core.render(fields, ext, cfg) or nil
    -- Never guess: books we can't identify with confidence stay where they are.
    if not rel then
        return { from = path, to = path, fields = fields, status = "review", why = why, embedded = embedded }
    end
    local target = unique_target(cfg.library_root .. "/" .. rel, path)
    if not target then return nil end
    return {
        from = path, to = target, fields = fields, why = why, embedded = embedded,
        status = (target == path) and "same" or "ok",
        confident_author = (conf >= 1) and fields.author or nil,
    }
end

-- opts: { dry_run = bool, manual = bool (ignore the "already handled" cache),
--         on_done = function(result), on_progress = function(i, n) }
function Organizer:run(opts)
    if self.running then return end
    local cfg = self.settings()
    if not cfg.library_root or not exists(cfg.library_root) then
        if opts.on_done then opts.on_done{ error = "no_root" } end
        return
    end
    self.running = true
    local files, seen = {}, {}
    for _, r in ipairs(scan_roots(cfg)) do
        for _, f in ipairs(collect(r, cfg, {})) do
            if not seen[f] then seen[f] = true; files[#files + 1] = f end
        end
    end

    local result = { moves = {}, review = 0, same = 0, failed = 0, total = #files,
        skipped = 0, unresolved = {} }
    local done = self.state:readSetting("done", {})
    local known = self.state:readSetting("authors", {})
    local deferred = {}
    local queue, i, pass = files, 0, 1

    local function finish()
        self.running = false
        if not opts.dry_run then
            self.state:saveSetting("done", done)
            self.state:saveSetting("authors", known)
            if #result.moves > 0 then self.state:saveSetting("last_run", result.moves) end
            self.state:flush()
        end
        if opts.on_done then opts.on_done(result) end
    end

    local function handle(plan, path, sig)
        if not plan then
            result.failed = result.failed + 1
        elseif plan.confident_author then
            known[Core.author_key(plan.confident_author)] = true
        end
        if not plan then return end
        if plan.status == "review" then
            if pass == 1 then
                deferred[#deferred + 1] = { path = path, sig = sig, embedded = plan.embedded }
            else
                result.review = result.review + 1
                done[path] = sig
                result.unresolved[#result.unresolved + 1] = { path = path, why = plan.why }
            end
        elseif plan.status == "same" then
            result.same = result.same + 1
            done[path] = sig
        elseif opts.dry_run then
            result.moves[#result.moves + 1] = { from = plan.from, to = plan.to, why = plan.why }
        else
            local made = mkdirs(Core.dirname(plan.to))
            if made and move_file(plan.from, plan.to) then
                move_metadata(plan.from, plan.to)
                for _, r in ipairs(scan_roots(cfg)) do
                    remove_empty_dirs(Core.dirname(plan.from), r)
                end
                result.moves[#result.moves + 1] = { from = plan.from, to = plan.to, why = plan.why }
                done[plan.to] = signature(plan.to)
                done[plan.from] = nil
            else
                result.failed = result.failed + 1
            end
        end
    end

    local function step()
        i = i + 1
        if i > #queue then
            if pass == 1 and #deferred > 0 then
                -- Second pass: now that we've learned authors from the whole library (and
                -- may use the internet), retry the books we couldn't place.
                pass, queue, i = 2, deferred, 0
                deferred = {}
                return UIManager:scheduleIn(0.05, step)
            end
            return finish()
        end
        local item = queue[i]
        local path = (pass == 1) and item or item.path
        local sig = signature(path)
        if sig and (opts.manual or pass == 2 or done[path] ~= sig) then
            local ok, plan = pcall(self.plan_one, self, path, cfg, known, pass == 2,
                pass == 2 and item.embedded or nil)
            handle(ok and plan or nil, path, sig)
        elseif sig then
            result.skipped = result.skipped + 1
        end
        if opts.on_progress then opts.on_progress(i, #queue) end
        UIManager:scheduleIn(0.05, step)
    end
    UIManager:scheduleIn(0.05, step)
end

-- Reverse the last real run.
function Organizer:undo()
    local moves = self.state:readSetting("last_run", {})
    local restored = 0
    local done = self.state:readSetting("done", {})
    for idx = #moves, 1, -1 do
        local m = moves[idx]
        if exists(m.to) and not exists(m.from) then
            if mkdirs(Core.dirname(m.from)) and move_file(m.to, m.from) then
                move_metadata(m.to, m.from)
                remove_empty_dirs(Core.dirname(m.to), (self.settings().library_root or "/"))
                done[m.to] = nil
                -- mark as handled so the automatic scan doesn't immediately re-file it
                done[m.from] = signature(m.from)
                restored = restored + 1
            end
        end
    end
    self.state:saveSetting("done", done)
    self.state:saveSetting("last_run", {})
    self.state:flush()
    return restored, #moves
end

return Organizer
