local builtin = require("telescope.builtin")
local api = vim.api

local M = {}

local BUF_NAME_MARK = "　➜ "
local COL_SEP = "│"

local function first_non_empty_line(bufnr)
    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for _, line in ipairs(lines) do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            local max_len = 30
            if #trimmed > max_len then
                return trimmed:sub(1, max_len) .. "…"
            end
            return trimmed
        end
    end
    return "[empty]"
end

local genLabels = function(total)
    local characters = M.config.quick_buffer_characters
    local hints = {""}
    local offset = 1
    while table.getn(hints) - offset + 1 < total or offset == 1 do
        local prefix = hints[offset]
        offset = offset + 1
        for i = 1, #characters do
            hints[#hints + 1] = prefix .. characters:sub(i,i)
        end
    end

    local ret = {}
    for i = offset, offset + total - 1, 1 do
        ret[#ret+1] = hints[i]
    end
    return ret
end

local buildMarks = function(bnr, ns_id, data)
    api.nvim_buf_clear_namespace(bnr, ns_id, 0, -1)
    local found = {}
    local view = vim.fn.winsaveview()
    vim.cmd("normal! 0gg")
    local pos = vim.fn.searchpos(BUF_NAME_MARK, "cW")
    while pos and pos[1] ~= 0 do
        found[#found+1] = pos
        pos = vim.fn.searchpos(BUF_NAME_MARK, "W")
    end
    local labels = genLabels(#found)
    local marks = {}
    local opts = {
      virt_text = {{"demo", "Search"}},
      virt_text_pos = 'overlay',
    }
    for i, pos in ipairs(found) do
        opts.virt_text = {{labels[i], "Search"}}
        marks[#marks + 1] = {
            id = api.nvim_buf_set_extmark(bnr, ns_id, pos[1] - 1, pos[2] - 1, opts),
            data = data[i],
            label = labels[i]
        }
    end
    vim.cmd("redraw")
    vim.fn.winrestview(view)
    return marks
end

-- Pack `entries` ({ name, current }) into lines no wider than max_width, using
-- at most max_height lines. Returns the lines (with a leading title slot and a
-- trailing blank line) and how many entries fit; entries beyond that get no mark.
local function packEntries(entries, max_width, max_height)
    local lines = {""}
    local count = 0
    local files = COL_SEP
    for _, e in ipairs(entries) do
        local entry = " "..BUF_NAME_MARK..e.name..(e.current and "*" or " ")..COL_SEP
        if files ~= COL_SEP and vim.fn.strdisplaywidth(files..entry) > max_width then
            lines[#lines + 1] = files
            files = COL_SEP
            if #lines - 1 >= max_height then
                break
            end
        end
        files = files..entry
        count = count + 1
    end
    if files ~= COL_SEP then
        lines[#lines + 1] = files
    end
    lines[#lines + 1] = ""
    return lines, count
end

local buildLinesForBuffers = function(max_width, max_height, exclude, names)
    local bufs = vim.fn.getbufinfo { buflisted = true }
    if #bufs == 1 then
        return {}, {}, 0
    end
    if exclude then
        bufs = vim.tbl_filter(function(b) return not exclude[b.bufnr] end, bufs)
        if #bufs == 0 then
            return {}, {}, 0
        end
    end
    table.sort(bufs, function(a, b)
        return a.lastused > b.lastused
    end)

    -- flat list in last-used order; names are unique (see uniqueDisplayNames),
    -- so no directory headings.
    local bnr = vim.fn.bufnr('%')
    local entries = {}
    for _, buf in ipairs(bufs) do
        entries[#entries + 1] = { name = names[buf.bufnr], current = buf.bufnr == bnr }
    end
    local lines, count = packEntries(entries, max_width, max_height)
    local bufNrs = {}
    for i = 1, count do
        bufNrs[i] = bufs[i].bufnr
    end
    return lines, bufNrs, count
end

local setTitle = function(lines, width, title)
    title = " "..title.." "
    -- split the padding so every title is exactly `width` wide, even when
    -- width - #title is odd (the right side gets the extra one)
    local pad = math.max(0, width - vim.fn.strdisplaywidth(title))
    local left = math.floor(pad / 2)
    lines[1] = string.rep("━", left)..title..string.rep("━", pad - left)
end
local layout = function(lines, max_width)
    local width = 0
    for _, line in ipairs(lines) do
        local w = vim.fn.strdisplaywidth(line)
        if w >= max_width then
            width = max_width
            break
        elseif w > width then
            width = w
        end
    end
    local height = 1
    for _, line in ipairs(lines) do
        height = height + math.ceil(vim.fn.strdisplaywidth(line) / width)
    end
    return width, height
end

local function has_value(tab, val)
    for index, value in ipairs(tab) do
        if value == val then
            return true
        end
    end

    return false
end

-- Recently opened files that are readable and not loaded as listed buffers.
local collectOldFiles = function(num)
    local bufNames = {}
    for _, buf in ipairs(vim.fn.getbufinfo { buflisted = true }) do
        bufNames[#bufNames + 1] = buf.name
    end

    local oldfiles = {}
    if num <= 0 then
        return oldfiles
    end
    for _, f in ipairs(vim.v.oldfiles) do
        if string.match(f, "term://.*") == nil and
            string.match(f, "surfingkeys://.*") == nil and
            string.match(f, "fugitive://.*") == nil and
            string.match(f, "/$") == nil and
            vim.fn.filereadable(f) == 1 and
            not has_value(bufNames, f) then
            oldfiles[#oldfiles + 1] = vim.fs.normalize(f)
            if #oldfiles >= num then
                break
            end
        end
    end
    return oldfiles
end

-- Flat list of old files labelled by names[path] (see uniqueDisplayNames).
local buildLinesForOldFiles = function(paths, lineTotal, max_width, names)
    local entries = {}
    for _, path in ipairs(paths) do
        entries[#entries + 1] = { name = names[path] }
    end
    local lines, count = packEntries(entries, max_width, lineTotal - 2)
    return lines, vim.list_slice(paths, 1, count)
end

local function bufDisplayName(bufnr)
    local name = api.nvim_buf_get_name(bufnr)
    local tail = string.match(vim.fs.normalize(name), ".*/(.*)")
    if tail == nil then
        tail = name
    end
    if tail == "" then
        tail = "▢ "..first_non_empty_line(bufnr)
    end
    return tail
end

-- Display names, keyed by bufnr for `bufnrs` and by path for `paths` (old files).
-- A name is the file name, prefixed with the fewest parent directories needed to
-- tell it apart from other entries with the same file name. Old files always get
-- at least their parent directory, as a hint of where they live.
local function uniqueDisplayNames(bufnrs, paths)
    local names, groups = {}, {}
    local function add(key, path, minDepth)
        local parts = vim.split(vim.fs.normalize(path), "/", { plain = true })
        local tail = parts[#parts]
        local g = groups[tail] or {}
        groups[tail] = g
        g[#g+1] = { key = key, parts = parts, minDepth = minDepth }
    end
    for _, b in ipairs(bufnrs) do
        if names[b] == nil then
            names[b] = bufDisplayName(b)
            local path = api.nvim_buf_get_name(b)
            if path ~= "" then
                add(b, path, 1)
            end
        end
    end
    for _, path in ipairs(paths or {}) do
        if names[path] == nil then
            names[path] = path
            add(path, path, 2)
        end
    end
    local function suffix(parts, k)
        return table.concat(parts, "/", math.max(1, #parts - k + 1))
    end
    for _, g in pairs(groups) do
        for _, e in ipairs(g) do
            local k = math.min(e.minDepth, #e.parts)
            while k < #e.parts do
                local s, clash = suffix(e.parts, k), false
                for _, o in ipairs(g) do
                    if o ~= e and suffix(o.parts, k) == s then
                        clash = true
                        break
                    end
                end
                if not clash then break end
                k = k + 1
            end
            names[e.key] = suffix(e.parts, k)
        end
    end
    return names
end

local function collectLeafBufs(node, out)
    if node[1] == "leaf" then
        out[#out+1] = api.nvim_win_get_buf(node[2])
    else
        for _, child in ipairs(node[2]) do
            collectLeafBufs(child, out)
        end
    end
    return out
end

local function isFloat(win)
    return api.nvim_win_get_config(win).relative ~= ""
end

-- A block is a list of lines, each line { text = string, wins = {winid...} },
-- plus its display width. Window ids per line are kept in left-to-right order.
local function padRight(text, width)
    return text..string.rep(" ", width - vim.fn.strdisplaywidth(text))
end

-- Render a winlayout() tree into a block that mirrors the on-screen placement:
-- "row" children (side by side) share lines, "col" children (stacked) are stacked.
local function layoutBlock(node, nr, cur_win, names)
    local kind = node[1]
    if kind == "leaf" then
        local win = node[2]
        local name = names[api.nvim_win_get_buf(win)]
        if win == cur_win then
            -- the current window needs no mark, it's where we already are
            local text = " "..name.."*"
            return { lines = {{ text = text, wins = {} }}, width = vim.fn.strdisplaywidth(text) }
        end
        local text = " "..BUF_NAME_MARK..name.." "
        return { lines = {{ text = text, wins = { win } }}, width = vim.fn.strdisplaywidth(text) }
    end
    local children = {}
    for _, child in ipairs(node[2]) do
        children[#children+1] = layoutBlock(child, nr, cur_win, names)
    end
    local block = { lines = {}, width = 0 }
    if kind == "col" then
        for _, c in ipairs(children) do
            for _, l in ipairs(c.lines) do
                block.lines[#block.lines+1] = l
            end
            block.width = math.max(block.width, c.width)
        end
    else -- "row"
        local height = 0
        for _, c in ipairs(children) do
            height = math.max(height, #c.lines)
        end
        for i = 1, height do
            local text, wins = "", {}
            for _, c in ipairs(children) do
                local l = c.lines[i]
                text = text..padRight(l and l.text or "", c.width)
                if l then
                    vim.list_extend(wins, l.wins)
                end
            end
            block.lines[i] = { text = text, wins = wins }
        end
        for _, c in ipairs(children) do
            block.width = block.width + c.width
        end
    end
    return block
end

-- Tabs: one cell per tab (matching the tabline order); inside each cell the
-- tab's windows are laid out the way they are placed on screen.
local buildLinesForTabs = function(names)
    local tabs = api.nvim_list_tabpages()
    local cur_win = api.nvim_get_current_win()
    local cells = {}
    local rows, total = 0, 0
    for _, tab in ipairs(tabs) do
        local nr = api.nvim_tabpage_get_number(tab)
        local block = layoutBlock(vim.fn.winlayout(nr), nr, cur_win, names)
        cells[#cells+1] = block
        rows = math.max(rows, #block.lines)
        for _, l in ipairs(block.lines) do
            total = total + #l.wins
        end
    end
    -- total excludes the current window, which gets no mark
    if #tabs < 2 and total < 1 then
        return {}, {}
    end

    -- lines are emitted top-down, left-right, which matches the mark search order
    local lines = {""}
    local data = {}
    for r = 1, rows do
        local line = COL_SEP
        for _, cell in ipairs(cells) do
            local l = cell.lines[r]
            line = line..padRight(l and l.text or "", cell.width)..COL_SEP
            if l then
                for _, win in ipairs(l.wins) do
                    data[#data+1] = { win = win }
                end
            end
        end
        lines[#lines+1] = line
    end
    lines[#lines+1] = ""
    return lines, data
end

-- Jump to a window already showing `bufnr`, preferring one in the current tab.
local function focusWindowWithBuf(bufnr)
    local wins = vim.fn.win_findbuf(bufnr)
    if #wins == 0 then
        return false
    end
    local cur_tab = api.nvim_get_current_tabpage()
    for _, win in ipairs(wins) do
        if api.nvim_win_get_tabpage(win) == cur_tab then
            api.nvim_set_current_win(win)
            return true
        end
    end
    api.nvim_set_current_win(wins[1])
    return true
end

local function findBufByName(path)
    for _, buf in ipairs(api.nvim_list_bufs()) do
        local name = api.nvim_buf_get_name(buf)
        if name ~= "" and vim.fs.normalize(name) == path then
            return buf
        end
    end
end

local buf_picker_id = vim.api.nvim_create_buf(false, true)
-- pcall: the name may already be taken if this module is reloaded
pcall(vim.api.nvim_buf_set_name, buf_picker_id, "[QuickBuffer]")
vim.bo[buf_picker_id].filetype = "quickbuffer"
local buf_picker_ns = api.nvim_create_namespace('quick_buffer')
local BS = vim.api.nvim_replace_termcodes("<BS>", true, true, true)
local ESC = vim.api.nvim_replace_termcodes("<Esc>", true, true, true)
function M.quickBuffers(config)
    -- build buffer names
    -- use the whole editor area (outermost window), not the current window
    local tabline = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #api.nvim_list_tabpages() > 1)) and 1 or 0
    local statusline = vim.o.laststatus > 0 and 1 or 0
    local max_width = vim.o.columns
    local max_height = vim.o.lines - vim.o.cmdheight - tabline - statusline - 2
    -- buffers whose names are shown: those in any tab's windows plus listed ones
    local nameBufs = {}
    for _, tab in ipairs(api.nvim_list_tabpages()) do
        collectLeafBufs(vim.fn.winlayout(api.nvim_tabpage_get_number(tab)), nameBufs)
    end
    for _, b in ipairs(vim.fn.getbufinfo { buflisted = true }) do
        nameBufs[#nameBufs+1] = b.bufnr
    end

    local tabLines, tabData, tabWidth, tabHeight
    local bufLines, bufData, bufTotal, bufWidth, bufHeight
    local function buildTabsAndBuffers(names)
        tabLines, tabData = buildLinesForTabs(names)
        tabWidth, tabHeight = 0, 0
        if #tabData > 0 then
            tabWidth, tabHeight = layout(tabLines, max_width)
        end

        -- buffers shown in a window listed in Tabs are already reachable, skip them
        local exclude = {}
        if #tabData > 0 then
            exclude[api.nvim_get_current_buf()] = true -- shown (unmarked) in Tabs
        end
        for _, w in ipairs(tabData) do
            exclude[api.nvim_win_get_buf(w.win)] = true
        end
        bufLines, bufData, bufTotal = buildLinesForBuffers(max_width, max_height - tabHeight, exclude, names)
        bufWidth, bufHeight = 0, 0
        if bufTotal > 0 then
            bufWidth, bufHeight = layout(bufLines, max_width)
        end
    end

    -- pass 1: names among buffers only, to know how many marks are left for old files
    local names = uniqueDisplayNames(nameBufs)
    buildTabsAndBuffers(names)
    local max_marks = #(M.config.quick_buffer_characters)
    local markTotal = #tabData + bufTotal
    local oldPaths = {}
    if markTotal < max_marks and tabHeight + bufHeight < max_height then
        oldPaths = collectOldFiles(max_marks - markTotal)
    end

    -- pass 2: names among buffers and old files together, so that labels are
    -- unique across all groups; rebuild Tabs/Buffers if any of their labels grew
    if #oldPaths > 0 then
        local all = uniqueDisplayNames(nameBufs, oldPaths)
        local changed = false
        for _, b in ipairs(nameBufs) do
            if all[b] ~= names[b] then
                changed = true
                break
            end
        end
        names = all
        if changed then
            buildTabsAndBuffers(names)
        end
    end

    local width = math.max(tabWidth, bufWidth)
    local height = tabHeight + bufHeight
    markTotal = #tabData + bufTotal

    local oldFileLines, oldFilePaths = {}, {}
    if #oldPaths > 0 and height < max_height then
        oldFileLines, oldFilePaths = buildLinesForOldFiles(oldPaths, max_height - height, max_width, names)
        if #oldFilePaths > 0 then
            local w, h = layout(oldFileLines, max_width)
            width = math.max(width, w)
            height = height + h
        end
    end

    -- assemble sections; data order must match mark order in the picker
    local lines, data = {}, {}
    local function append(sectionLines, sectionData, title)
        setTitle(sectionLines, width, title)
        for _, l in ipairs(sectionLines) do
            lines[#lines+1] = l
        end
        for _, d in ipairs(sectionData) do
            data[#data+1] = d
        end
    end
    if #tabData > 0 then
        append(tabLines, tabData, "Tabs|"..#tabData)
    end
    if bufTotal > 0 then
        append(bufLines, bufData, "Buffers|"..bufTotal)
    end
    if #oldFilePaths > 0 then
        append(oldFileLines, oldFilePaths, "Old files|"..#oldFilePaths)
    end

    -- show buffer picker
    local original_win_id = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(buf_picker_id, 0, -1, true, lines)
    local buf_picker_win_id = vim.api.nvim_open_win(buf_picker_id, false, {relative='editor', row=tabline, col=0, width=width, height=height + 2})
    vim.wo[buf_picker_win_id].relativenumber = false
    vim.wo[buf_picker_win_id].number = false
    vim.api.nvim_set_current_win(buf_picker_win_id )

    -- loop for user picking
    local bnr = vim.fn.bufnr('%')
    local pick = ""
    local ch = ""
    local newTab = false
    local matches = buildMarks(bnr, buf_picker_ns, data)
    repeat
        -- ch = vim.fn.getcharstr()
        local ok, ret = pcall(vim.fn.getcharstr)
        if ok then
            ch = ret
        else
            ch = ESC
            break
        end
        if ch == BS then
            pick = ""
            newTab = false
            matches = buildMarks(bnr, buf_picker_ns, data)
        elseif ch == ESC then
            break
        else
            -- Shift + mark: open the picked one in a new tab
            local lower = ch:lower()
            if lower ~= ch and not M.config.quick_buffer_characters:find(ch, 1, true) then
                newTab = true
                ch = lower
            end
            pick = pick .. ch
        end
        local nextMatches = {}
        for _, m in ipairs(matches) do
            if m.label:sub(1, #pick) == pick then
                local mark = api.nvim_buf_get_extmark_by_id(bnr, buf_picker_ns, m.id, { details = true })
                local opts = {
                  virt_text = {{"demo", "Comment"}},
                  virt_text_pos = 'overlay',
                }
                opts.virt_text = {{pick, "Comment"}}
                api.nvim_buf_set_extmark(bnr, buf_picker_ns, mark[1], mark[2], opts)
                nextMatches[#nextMatches+1] = m
            else
                api.nvim_buf_del_extmark(bnr, buf_picker_ns, m.id)
            end
        end
        vim.cmd("redraw")
        matches = nextMatches
    until(#matches < 2)

    api.nvim_buf_clear_namespace(bnr, buf_picker_ns, 0, -1)

    if api.nvim_win_is_valid(buf_picker_win_id) then
        vim.api.nvim_win_close(buf_picker_win_id , true)
    end
    -- the original window may be gone (e.g. a float closed on WinLeave)
    if api.nvim_win_is_valid(original_win_id) then
        vim.api.nvim_set_current_win(original_win_id)
    end
    if #matches == 1 then
        local data = matches[1].data
        if newTab then
            local buf = data
            if type(data) == "table" then
                buf = api.nvim_win_is_valid(data.win) and api.nvim_win_get_buf(data.win) or nil
            elseif type(data) == "string" then
                buf = findBufByName(data)
            end
            if buf then
                vim.cmd(string.format("tab sbuffer %d", buf))
            elseif type(data) == "string" then
                vim.cmd("tabedit " .. vim.fn.fnameescape(data))
            end
            return
        end
        if type(data) == "table" and data.win then
            if api.nvim_win_is_valid(data.win) then
                api.nvim_set_current_win(data.win)
            end
            return
        end
        local target = type(data) == "number" and data or findBufByName(data)
        if not (target and focusWindowWithBuf(target)) then
            if type(data) == "number" then
                vim.cmd(string.format("b %d", data))
            else
                vim.cmd(string.format("e %s", data))
            end
        end
    elseif ch ~= ESC then
        builtin.oldfiles()
    end
end

return M
