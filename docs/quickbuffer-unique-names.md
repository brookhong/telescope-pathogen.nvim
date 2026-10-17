# Quick buffer: unique names

The quick buffer picker has three groups, all labelled with file names:

- **Tabs** shows each tab's windows the way they are split on screen;
- **Buffers** lists the other listed buffers, as a flat list;
- **Old files** lists recently opened files that aren't loaded, as a flat list.

When different entries have the same file name (`init.lua`, `config.md`, ...),
the label gets **the fewest parent directories needed to tell them apart**.
Old files always get **at least their parent directory**, as a hint of where
they live (you know what your open buffers are, but an old `todo.md` could be
from anywhere):

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━ Tabs|2 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
│ ➜ x/src/init.lua │ z/init.lua* ➜ y/src/init.lua │

━━━━━━━━━━━━━━━━━━━━━━━━━━ Buffers|2 ━━━━━━━━━━━━━━━━━━━━━━━━━━
│ ➜ w/src/init.lua │ ➜ main.lua │

━━━━━━━━━━━━━━━━━━━━━━━━━ Old files|4 ━━━━━━━━━━━━━━━━━━━━━━━━━
│ ➜ q/src/init.lua │ ➜ notes/config.md │ ➜ dot/config.md │
│ ➜ qbt/solo.txt │
```

Because labels are unique, no group needs directory headings.

Everything below lives in `lua/pathogen/quickbuffer.lua`.

## Overview

```
M.quickBuffers()
 ├─ nameBufs = collectLeafBufs(winlayout(tab))  -- buffers in every tab's windows
 │           + getbufinfo{ buflisted = true }    -- plus every listed buffer
 │
 ├─ pass 1: names = uniqueDisplayNames(nameBufs)
 │          buildTabsAndBuffers(names)           -- Tabs + Buffers lines
 │          oldPaths = collectOldFiles(marks left)
 │
 ├─ pass 2: names = uniqueDisplayNames(nameBufs, oldPaths)
 │          if any buffer label changed: buildTabsAndBuffers(names)
 │
 └─ buildLinesForOldFiles(oldPaths, ..., names)
```

The names are worked out in `M.quickBuffers` and passed into every group, so:

- an entry gets the same label everywhere it appears;
- clashes are detected across tabs **and** across groups. For example, a
  buffer `z/main.lua` and an old file `k/main.lua` are told apart, even though
  they are in different groups.

`uniqueDisplayNames` is a `local function` defined after
`buildLinesForBuffers`, so it can't be called from there directly. That's
another reason `names` is passed in as a parameter.

### Why two passes

How many old files are shown depends on how many marks
(`quick_buffer_characters`) Tabs and Buffers have already used. That needs
Tabs and Buffers built first, which needs names. But the names should also
take old files into account. So:

1. **Pass 1** names buffers alone, builds Tabs and Buffers, and from the marks
   left over works out which old files to show (`collectOldFiles`).
2. **Pass 2** names buffers and those old files together. If an old file made
   any buffer's label longer (e.g. buffer `main.lua` becomes `z/main.lua`
   because of old file `k/main.lua`), Tabs and Buffers are rebuilt with the new
   labels. Otherwise the pass-1 lines are kept.

Rebuilding doesn't change the number of Tabs/Buffers entries (except in the
rare case where longer labels make Buffers run out of height), so the old-file
list from pass 1 stays valid.

## Step 1: collect the entries

### Windows — `collectLeafBufs(node, out)`

`vim.fn.winlayout(tabnr)` returns a tree for a tab:

```lua
{ "row", { { "leaf", 1001 }, { "col", { { "leaf", 1002 }, { "leaf", 1003 } } } } }
```

`collectLeafBufs` walks the tree and, for every `leaf` (a window), adds
`nvim_win_get_buf(win)` to `out`. Floating windows are not part of
`winlayout()`, so they are left out automatically. The list can hold
duplicates (the same buffer in several windows); step 2 deals with that.

### Listed buffers

Then every `bufnr` from `vim.fn.getbufinfo { buflisted = true }` is added to
the same list. Most of them are already there (shown in a window); step 2
handles each buffer only once.

### Old files — `collectOldFiles(num)`

Up to `num` entries of `vim.v.oldfiles`, skipping `term://`, `surfingkeys://`,
`fugitive://` and directory entries, unreadable files, and files that are
already listed buffers. Paths are normalized with `vim.fs.normalize`.

## Step 2: work out the names — `uniqueDisplayNames(bufnrs, paths)`

Returns one table of labels: `names[bufnr]` for buffers and `names[path]` for
old files. A bufnr is a number and a path is a string, so the two kinds of key
can't collide.

### 2a. Entries and grouping

Each entry is added **once** (`if names[key] == nil`). This matters: a buffer
shown in two windows must not be seen as clashing with itself.

- **Buffers**: the starting name comes from `bufDisplayName(bufnr)`: the file
  name, or for an unnamed buffer its first non-empty line (or `[empty]`).
  Buffers **with a path** are added with `minDepth = 1`. Unnamed buffers are
  not added, so they never get a prefix; they have no path to take directories
  from.
- **Old files**: added with `minDepth = 2` (file name plus parent directory).

Each added entry stores the normalized path split on `/` and is grouped by its
last part (the file name):

```
/tmp/qbt/x/src/init.lua  ->  { "", "tmp", "qbt", "x", "src", "init.lua" }
```

The leading `""` comes from the leading `/`.

### 2b. Resolving clashes

```lua
local function suffix(parts, k)          -- last k parts joined by "/"
    return table.concat(parts, "/", math.max(1, #parts - k + 1))
end
```

For each entry `e` in every group, including groups with a single entry:

1. Start with `k = min(e.minDepth, #e.parts)`: the file name for buffers, the
   parent directory plus file name for old files.
2. If any **other** entry in the group has the same `suffix(parts, k)`, it
   clashes, so `k = k + 1`.
3. Stop at the first `k` that doesn't clash, or when `k` reaches the full
   path length (`k < #e.parts`), so the loop can't run past the root.
4. `names[e.key] = suffix(e.parts, k)`.

A buffer alone in its group stays a bare file name (`main.lua`); an old file
alone in its group gets its parent directory (`qbt/solo.txt`).

Each entry picks its own `k`, so one entry can stay short while its siblings
need more directories:

| entry                       | k=1   | k=2            | k=3    | label            |
|-----------------------------|-------|----------------|--------|------------------|
| buffer `…/x/src/init.lua`   | clash | clash with `y` | unique | `x/src/init.lua` |
| buffer `…/y/src/init.lua`   | clash | clash with `x` | unique | `y/src/init.lua` |
| buffer `…/z/init.lua`       | clash | unique         | –      | `z/init.lua`     |

Clashes are checked against **all** entries in the group, whatever their
`minDepth`. So a buffer `main.lua` clashes at `k = 1` with an old file
`k/main.lua` (whose suffix at `k = 1` is also `main.lua`), and becomes
`z/main.lua`. That way a bare `main.lua` never sits next to `k/main.lua`,
which would make it unclear which `main.lua` the bare one is.

#### Edge case: one path is a suffix of another

```
/a/init.lua    -> { "", "a", "init.lua" }
/b/a/init.lua  -> { "", "b", "a", "init.lua" }
```

At `k = 2` both are `a/init.lua`. At `k = 3` the first becomes `/a/init.lua`
(the leading `""` part adds the leading `/`) and the second `b/a/init.lua`, so
they are told apart, and the leading `/` shows that the first one is the
shorter, rooted path.

For paths that don't start at the root, the shorter path simply takes its next
parent directory:

```
/tmp/qbt2/a/init.lua    -> qbt2/a/init.lua
/tmp/qbt2/b/a/init.lua  -> b/a/init.lua
```

## Step 3: draw the entries

### Tabs — `buildLinesForTabs(names)` / `layoutBlock(node, nr, cur_win, names)`

`names` is passed down the recursive `layoutBlock` call. At each leaf:

```lua
local name = names[api.nvim_win_get_buf(win)]
```

Side-by-side windows share a line, stacked windows are stacked, cells are
padded to the same display width (`strdisplaywidth`), marks are assigned
top-down and left-to-right, and the current window is shown without a mark
(with a trailing `*`).

### Flat lists — `packEntries(entries, max_width, max_height)`

Shared by Buffers and Old files. Each entry is `{ name, current }` and is
drawn as ` ➜ name ` (or ` ➜ name*` for the current buffer) followed by `COL_SEP` (`│`).
An entry starts a new line when adding it would make the current line wider
than `max_width` (measured with `strdisplaywidth`). Packing stops once
`max_height` lines are used. Returns the lines (with a title slot first and a
blank line last) and **how many entries fit**. Entries that don't fit get no
mark, so the marks always match the entries shown.

### Buffers — `buildLinesForBuffers(max_width, max_height, exclude, names)`

Filters out the `exclude`d buffers (those shown in Tabs), sorts the rest by
last use, and packs them with labels `names[buf.bufnr]`.

### Old files — `buildLinesForOldFiles(paths, lineTotal, max_width, names)`

Packs `paths` with labels `names[path]` into the height left over, and returns
only the paths that fit. A picked old file is still opened by its full path.

## Scope and limitations

- Unnamed buffers are labelled by their content and never get a prefix. If
  such a label happens to equal a file name, the two are not told apart.
- Pass 2 takes into account all old files from `collectOldFiles`. If Old
  files then runs out of height, a file that isn't shown may still have made
  another label longer. This is rare and harmless: the label is still unique,
  just longer than needed.
- Cost: for a group of `n` same-named entries whose paths have at most `d`
  parts, the work is `O(n² · d)`. With at most `#quick_buffer_characters`
  marks, that's negligible.
