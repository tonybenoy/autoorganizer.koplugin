# autoorganizer.koplugin — Library organiser for KOReader

Finds books anywhere on your device and files them tidily, e.g.

```
Sanderson, Brandon/The Stormlight Archive/01 - The Way of Kings.epub
Herbert, Frank/Dune.epub
```

## What it does
- **Scans the whole device by default** (the storage your library lives on, e.g. `/mnt/us` on
  Kindle, `/mnt/onboard` on Kobo) and files every book into your library folder.
- **Include / exclude rules** to narrow that down. Rules are absolute paths
  (`/mnt/us/documents/Comics`) or folder names (`Downloads`), `*` wildcards allowed; excludes win.
  System folders (`koreader`, `extensions`, `system`, …) are excluded by default.
- **Reads embedded tags first** (title, author, Calibre series), then understands filenames:
  `Title - Author`, `Author - Title`, `Title -- Author -- Series, N -- year -- hash`,
  `(Series, Book N)`, `(A Foo Novel)`, `Series [2]-Title`, `Feast for Crows, A`, `Last, First`,
  site junk like `PDFDrive.com`, truncated names, …
- **Works out which side of `X - Y` is the author** from name shape, a first-name list, authors
  learned from your other books' tags, and (optionally) an Open Library lookup.
- **Never guesses**: if it isn't confident, the book stays exactly where it is.
- Reading progress, bookmarks and history move with the book. Preview (dry run) shows *why*
  each book would be filed where; **Undo last run** reverses a run.
- KOReader can't watch folders, so automatic mode scans on start, on wake, on USB unplug and
  every 10 minutes while the file manager is open. Already-handled books are skipped.

## Install
Copy this folder to `koreader/plugins/autoorganizer.koplugin` and restart KOReader:

```
cd koreader/plugins && git clone https://github.com/tonybenoy/autoorganizer.koplugin
```

Then open **Tools → Library organiser**, pick a **Library folder** (where books are filed),
and run **Preview (dry run)** first. **Automatic organising is off by default** — turn it on
once the preview looks right.

## Layout
Both templates are configurable (Layout menu). Placeholders: `{author} {series} {index} {title}`;
use `/` for folders. Author can be "Last, First" or "First Last".

## Caveats
- Early version. Test on a small folder first and check the Preview.
- Books bought from the Kindle store (DRM `.azw`) are included in a whole-device scan; moving
  them into subfolders can hide them from Kindle's own library screen. Exclude them if you use it.
- Open Library provides author/title, not reliable series info; series comes from tags or filenames.
- Moving reading progress uses KOReader internals (`DocSettings.updateLocation`,
  `ReadHistory:updateItemByPath`) that may differ between versions.

## Tests
The naming logic is pure Lua: `lua tests/test_core.lua` (or `luajittex --luaonly tests/test_core.lua`).

## License
MIT
