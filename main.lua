local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Core = require("autoorganizer_core")
local Organizer = require("autoorganizer_organizer")
local _ = require("gettext")

local AutoOrganizer = WidgetContainer:extend{
    name = "autoorganizer",
    is_doc_only = false,
}

local AUTO_DELAY = 10          -- seconds after start/resume before the automatic scan
local DEFAULT_INTERVAL = 10 * 60

function AutoOrganizer:config()
    local cfg = G_reader_settings:readSetting("autoorganizer")
    if not cfg then
        -- migrate settings from the plugin's former name ("sbm")
        cfg = G_reader_settings:readSetting("sbm") or {}
        G_reader_settings:saveSetting("autoorganizer", cfg)
    end
    for k, v in pairs(Core.DEFAULTS) do
        if cfg[k] == nil then cfg[k] = v end
    end
    -- Auto-organising is opt-in: run Preview first, then turn it on.
    if cfg.auto == nil then cfg.auto = false end
    if not cfg.scan_roots or #cfg.scan_roots == 0 then
        -- default: the whole device storage the library lives on
        local home = cfg.library_root or G_reader_settings:readSetting("home_dir")
        cfg.scan_roots = { Core.default_scan_root(home) }
    end
    if cfg.excludes == nil then cfg.excludes = Core.DEFAULT_EXCLUDES end
    if cfg.includes == nil then cfg.includes = {} end
    if cfg.online_lookup == nil then cfg.online_lookup = true end
    cfg.interval = cfg.interval or DEFAULT_INTERVAL
    return cfg
end

function AutoOrganizer:set(key, value)
    local cfg = self:config()
    cfg[key] = value
    G_reader_settings:saveSetting("autoorganizer", cfg)
end

function AutoOrganizer:init()
    self.organizer = Organizer:new(function() return self:config() end)
    self.ui.menu:registerToMainMenu(self)
    -- Only the file manager auto-scans; never touch files while a book is open.
    self.in_fm = self.ui.document == nil
    self._tick = function() self:autoRun() end
    if self.in_fm then self:scheduleAuto(AUTO_DELAY) end
end

function AutoOrganizer:scheduleAuto(delay)
    UIManager:unschedule(self._tick)
    local cfg = self:config()
    if self.in_fm and cfg.auto and cfg.library_root then
        UIManager:scheduleIn(delay or cfg.interval, self._tick)
    end
end

function AutoOrganizer:autoRun()
    local cfg = self:config()
    if not (self.in_fm and cfg.auto and cfg.library_root) then return end
    self.organizer:run{
        on_done = function(r)
            if r.moves and #r.moves > 0 then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Library organiser: filed %d book(s), %d need review."),
                        #r.moves, r.review),
                    timeout = 4,
                })
                self:refreshFileManager()
            end
            self:scheduleAuto()
        end,
    }
end

function AutoOrganizer:refreshFileManager()
    pcall(function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then FileManager.instance:onRefresh() end
    end)
end

-- Books copied while the device was asleep/USB-connected are picked up on wake.
function AutoOrganizer:onResume() self:scheduleAuto(AUTO_DELAY) end
function AutoOrganizer:onUsbPlugOut() self:scheduleAuto(AUTO_DELAY) end
function AutoOrganizer:onCloseWidget() UIManager:unschedule(self._tick) end

function AutoOrganizer:manualRun(dry_run)
    local cfg = self:config()
    if not cfg.library_root then
        UIManager:show(InfoMessage:new{ text = _("Choose a library folder first.") })
        return
    end
    local progress = InfoMessage:new{ text = _("Organising library…") }
    UIManager:show(progress)
    self.organizer:run{
        dry_run = dry_run,
        manual = true,
        on_done = function(r)
            UIManager:close(progress)
            if r.error then
                UIManager:show(InfoMessage:new{ text = _("Library folder not found.") })
                return
            end
            local lines = {
                string.format(_("%d books scanned: %d to move, %d already in place, %d left alone (unclear), %d failed."),
                    r.total, #r.moves, r.same, r.review, r.failed),
                "",
            }
            for _, m in ipairs(r.moves) do
                lines[#lines + 1] = m.from .. "\n   → " .. m.to .. "\n   (" .. (m.why or "?") .. ")"
            end
            if #r.unresolved > 0 then
                lines[#lines + 1] = ""
                lines[#lines + 1] = _("Left where they are (couldn't identify with confidence):")
                for _, u in ipairs(r.unresolved) do
                    lines[#lines + 1] = u.path .. "\n   (" .. (u.why or "?") .. ")"
                end
            end
            UIManager:show(TextViewer:new{
                title = dry_run and _("Preview (nothing moved)") or _("Organised"),
                text = table.concat(lines, "\n"),
            })
            if not dry_run then self:refreshFileManager() end
        end,
    }
end

function AutoOrganizer:promptText(title, key, hint)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = self:config()[key],
        description = hint,
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = dialog:getInputText()
                if v and v ~= "" then self:set(key, v) end
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Edit a list setting (one entry per line).
function AutoOrganizer:promptList(title, key, hint)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = table.concat(self:config()[key] or {}, "\n"),
        description = hint,
        allow_newline = true,
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), callback = function()
                local list = {}
                for line in (dialog:getInputText() or ""):gmatch("[^\n]+") do
                    line = Core.trim(line)
                    if line ~= "" then list[#list + 1] = line end
                end
                self:set(key, list)
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AutoOrganizer:pickFolder(on_pick)
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file = false,
        path = self:config().library_root or G_reader_settings:readSetting("home_dir"),
        onConfirm = on_pick,
    })
end

function AutoOrganizer:addToMainMenu(menu_items)
    local hint = _("Placeholders: {author} {series} {index} {title}. Use / to make folders.")
    menu_items.autoorganizer = {
        text = _("Library organiser"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("Organise now"), callback = function() self:manualRun(false) end },
            { text = _("Preview (dry run)"), callback = function() self:manualRun(true) end },
            { text = _("Undo last run"), callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Move the books from the last run back to where they were?"),
                    ok_callback = function()
                        local restored, total = self.organizer:undo()
                        UIManager:show(InfoMessage:new{
                            text = string.format(_("Restored %d of %d books."), restored, total) })
                        self:refreshFileManager()
                    end,
                })
            end },
            { text = _("Automatic organising"), checked_func = function() return self:config().auto end,
              callback = function()
                  self:set("auto", not self:config().auto)
                  self:scheduleAuto(AUTO_DELAY)
              end, separator = true },
            { text_func = function()
                  return _("Library folder: ") .. (self:config().library_root or _("not set"))
              end,
              keep_menu_open = true,
              callback = function(touchmenu)
                  self:pickFolder(function(path)
                      self:set("library_root", path)
                      if touchmenu then touchmenu:updateItems() end
                  end)
              end },
            { text = _("Scan scope"),
              sub_item_table = {
                  { text_func = function()
                        return string.format(_("Folders to scan (%d) — default: whole device"),
                            #self:config().scan_roots)
                    end,
                    keep_menu_open = true,
                    sub_item_table_func = function()
                        local items = {
                            { text = _("Add folder…"), callback = function()
                                  self:pickFolder(function(path)
                                      local list = self:config().scan_roots
                                      list[#list + 1] = path
                                      self:set("scan_roots", list)
                                  end)
                              end },
                            { text = _("Reset to whole device"), callback = function()
                                  self:set("scan_roots", nil)
                              end },
                        }
                        for _, p in ipairs(self:config().scan_roots) do
                            items[#items + 1] = { text = p, enabled = false }
                        end
                        return items
                    end },
                  { text = _("Include rules (only scan these)"), keep_menu_open = true,
                    callback = function()
                        self:promptList(_("Include rules"), "includes",
                            _("One per line. Empty = everything. Absolute path (/mnt/us/documents/Comics) or folder name (Novels). * wildcards allowed."))
                    end },
                  { text = _("Exclude rules (never scan these)"), keep_menu_open = true,
                    callback = function()
                        self:promptList(_("Exclude rules"), "excludes",
                            _("One per line. Absolute path or folder name, * wildcards allowed. Excludes win over includes."))
                    end },
                  { text = _("Reset rules to defaults"), callback = function()
                        self:set("includes", {})
                        self:set("excludes", nil)
                    end },
              } },
            { text = _("Look up missing details online"),
              checked_func = function() return self:config().online_lookup end,
              callback = function() self:set("online_lookup", not self:config().online_lookup) end,
              separator = true },
            { text = _("Layout"),
              sub_item_table = {
                  { text = _("Series books template"), keep_menu_open = true,
                    callback = function() self:promptText(_("Series books"), "series_template", hint) end },
                  { text = _("Standalone books template"), keep_menu_open = true,
                    callback = function() self:promptText(_("Standalone books"), "single_template", hint) end },
                  { text = _("Author as “Last, First”"),
                    checked_func = function() return self:config().author_format == "last_first" end,
                    radio = true,
                    callback = function() self:set("author_format", "last_first") end },
                  { text = _("Author as “First Last”"),
                    checked_func = function() return self:config().author_format == "first_last" end,
                    radio = true,
                    callback = function() self:set("author_format", "first_last") end },
                  { text = _("Reset to defaults"), callback = function()
                        self:set("series_template", Core.DEFAULTS.series_template)
                        self:set("single_template", Core.DEFAULTS.single_template)
                        self:set("author_format", Core.DEFAULTS.author_format)
                    end },
              } },
        },
    }
end

return AutoOrganizer
