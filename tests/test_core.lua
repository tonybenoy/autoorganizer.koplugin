-- Run from the repo root:  lua tests/test_core.lua   (Lua 5.1 / LuaJIT / 5.4 all work)
--   or without Lua installed:  luajittex --luaonly tests/test_core.lua
package.path = "./?.lua;" .. package.path
local Core = require("autoorganizer_core")

local fails = 0
local function eq(got, want, label)
    if got ~= want then
        fails = fails + 1
        print(string.format("FAIL %s\n  got:  %s\n  want: %s", label, tostring(got), tostring(want)))
    end
end

-- Run a filename through the whole pipeline; returns the rendered path or nil if the
-- book would be left alone.
local function file(name, embedded, known)
    local f, conf = Core.identify("/x/" .. name, embedded, known, "last_first")
    if conf < Core.ACCEPT then return nil, f, conf end
    return Core.render(f, Core.get_ext(name), Core.DEFAULTS), f, conf
end
local known = {}
known[Core.author_key("Frank Herbert")] = true

-- authors ---------------------------------------------------------------
eq(Core.normalize_author("Brandon Sanderson", "last_first"), "Sanderson, Brandon", "author flip")
eq(Core.normalize_author("Sanderson, Brandon", "last_first"), "Sanderson, Brandon", "author keep")
eq(Core.normalize_author("Sanderson, Brandon", "first_last"), "Brandon Sanderson", "author unflip")
eq(Core.normalize_author("Martin Luther King Jr.", "last_first"), "King Jr., Martin Luther", "suffix")
eq(Core.normalize_author("Neil Gaiman\nTerry Pratchett", "last_first"), "Gaiman, Neil", "first of many")
eq(Core.normalize_author("Unknown", "last_first"), nil, "junk author")
eq(Core.author_key("Herbert, Frank"), Core.author_key("Frank Herbert"), "author key order-free")
eq(Core.author_key("George R.R. Martin"), Core.author_key("Martin, George R R"), "author key initials")

-- name shape ------------------------------------------------------------
eq(Core.score_author("Frank Herbert") > Core.score_author("Dune Messiah"), true, "first name beats title")
eq(Core.score_author("Children of Memory") < 0.4, true, "stopword title")
eq(Core.score_author("Feast for Crows, A"), 0, "article after comma is a title")
eq(Core.score_author("Gibson, William") > 0.8, true, "Last, First")
eq(Core.score_author("New Title 1"), 0, "digits are not names")

-- scope rules -----------------------------------------------------------
eq(Core.rule_matches("Downloads", "/mnt/us/documents/Downloads/Items01"), true, "bare name any depth")
eq(Core.rule_matches("/mnt/us/koreader", "/mnt/us/koreader/plugins"), true, "abs prefix")
eq(Core.rule_matches("/mnt/us/koreader", "/mnt/us/koreader2"), false, "abs prefix is whole component")
eq(Core.rule_matches("*.old", "/mnt/us/documents/books.old"), true, "glob")
eq(Core.included({}, "/anything", true), true, "no includes = all")
eq(Core.included({ "/mnt/us/documents/Novels" }, "/mnt/us/documents/Novels/a.epub", false), true, "inside include")
eq(Core.included({ "/mnt/us/documents/Novels" }, "/mnt/us/documents/Comics/a.cbz", false), false, "outside include")
eq(Core.included({ "/mnt/us/documents/Novels" }, "/mnt/us/documents", true), true, "ancestor of include is traversable")
eq(Core.default_scan_root("/mnt/us/documents"), "/mnt/us", "kindle root")
eq(Core.default_scan_root("/mnt/onboard/books"), "/mnt/onboard", "kobo root")

-- real filenames from the device, no tags ------------------------------
eq((file("Dune Messiah - Frank Herbert.mobi", nil, known)), "Herbert, Frank/Dune Messiah.mobi", "Title - Author")
eq((file("Frank Herbert - Dune.epub", nil, known)), "Herbert, Frank/Dune.epub", "Author - Title")
eq((file("Insurgent - Veronica Roth.azw3")), "Roth, Veronica/Insurgent.azw3", "first name list")
eq((file("Children of Memory - Adrian Tchaikovsky.mobi")), "Tchaikovsky, Adrian/Children of Memory.mobi", "stopword title")
eq((file("Selfish Gene, The - Richard Dawkins.mobi")), "Dawkins, Richard/The Selfish Gene.mobi", "trailing article")
eq((file("Storm of Swords, A - George R. R. Martin.pdf")), "Martin, George R. R/A Storm of Swords.pdf", "article + initials")
eq((file("Heaven's River (Bobiverse Book 4) - Taylor, Dennis E_.mobi")),
    "Taylor, Dennis E/Bobiverse/04 - Heaven's River.mobi", "series in parens + Last, First")
eq((file("We Are Legion (We Are Bob) (Bobiverse Book 1) - Dennis E. Taylor.mobi")),
    "Taylor, Dennis E/Bobiverse/01 - We Are Legion (We Are Bob).mobi", "two paren groups")
eq((file("Dance With Dragons (A Song of Ice and Fire, Book 5), A - George R. R. Martin.mobi")),
    "Martin, George R. R/A Song of Ice and Fire/05 - A Dance With Dragons.mobi", "series + article after parens")
eq((file("Ice & Fire [2]-A Clash of Kings - George R.R. Martin.mobi")),
    "Martin, George R.R/Ice & Fire/02 - A Clash of Kings.mobi", "bracket index")
eq((file("Dune (40th Anniversary Edition) - Herbert, Frank.mobi")), "Herbert, Frank/Dune.mobi", "edition noise dropped")
eq((file("Naked Statistics_ Stripping the Dread from the Data - PDFDrive.com - Charles Wheelan.mobi")),
    "Wheelan, Charles/Naked Statistics Stripping the Dread from the Data.mobi", "site junk + underscore colon")

-- Anna's Archive style --------------------------------------------------
eq((file("Count Zero -- Gibson, William -- Sprawl 2, 2010 -- f8851bdebc53b061f57d36e5633a31ab -- Anna’s Arch.epub")),
    "Gibson, William/Sprawl/02 - Count Zero.epub", "double-dash format with series")
eq((file("Hunger Games 2 - Catching Fire -- Suzanne Collins -- Hunger Games 2_ 2010 -- 484447d6dbd1150e26982b7.mobi")),
    "Collins, Suzanne/Hunger Games/02 - Catching Fire.mobi", "series prefix in title")
eq((file("Sunrise on the Reaping (A Hunger Games Novel) -- Suzanne Collins -- 2025-03-18 -- Scholastic UK -- i.epub")),
    "Collins, Suzanne/Hunger Games/Sunrise on the Reaping.epub", "A X Novel -> series, no index")

eq((file("The Hunger Games Trilogy (Hunger Games _ Catching Fire _ -- Suzanne Collins_ Carolyn McCormick -- 20.epub")),
    "Collins, Suzanne/The Hunger Games Trilogy.epub", "truncated name: open paren dropped")
eq((file("The Hunger Games (Hunger Games Trilogy_ Book 1) -- Suzanne Collins _Collins_ Suzanne_ -- Hunger Game.azw3")),
    "Collins, Suzanne/Hunger Games Trilogy/01 - The Hunger Games.azw3", "truncated name: repeated author")

-- must NOT guess --------------------------------------------------------
eq((file("thinkstats - Unknown.mobi")), nil, "unknown author stays")
eq((file("New Title 1 - Hugh Howey.mobi")), nil, "placeholder title stays")
eq((file("some_random_book.pdf")), nil, "title only stays (needs online lookup)")

-- embedded tags ---------------------------------------------------------
local out = file("whatever.epub", { title = "The Way of Kings", author = "Brandon Sanderson",
    series = "The Stormlight Archive", index = 1 })
eq(out, "Sanderson, Brandon/The Stormlight Archive/01 - The Way of Kings.epub", "embedded complete")
out = file("Divergent.azw3", { title = "Divergent - Veronica Roth", author = "Veronica Roth" })
eq(out, "Roth, Veronica/Divergent.azw3", "embedded title with trailing author")
out = file("Dune Messiah - Frank Herbert.mobi", { author = "Frank Herbert" })
eq(out, "Herbert, Frank/Dune Messiah.mobi", "author tag orients filename")
out = file("Foo Bar - Baz Qux.mobi", { author = "Baz Qux" })
eq(out, "Qux, Baz/Foo Bar.mobi", "author tag orients ambiguous filename")

-- rendering -------------------------------------------------------------
local cfg = Core.DEFAULTS
local fl = { title = "Words of Radiance: Part 1?", author = "A B", series = "S", index = 2.5 }
eq(Core.render(fl, "epub", cfg), "A B/S/02.5 - Words of Radiance Part 1.epub", "sanitize + fractional index")
eq(Core.render({ title = "T", author = "A B", series = "Cool Series" }, "epub", cfg),
    "A B/Cool Series/T.epub", "series without index")
eq(Core.render({ title = "No Author" }, "epub", cfg), nil, "incomplete -> nil")

eq(Core.similarity("The Way of Kings", "Way of Kings, The") >= 0.8, true, "similar titles")
eq(Core.similarity("Dune", "Dune Messiah") < 0.8, true, "different titles")

print(fails == 0 and "all core tests passed" or (fails .. " failure(s)"))
os.exit(fails == 0 and 0 or 1)
