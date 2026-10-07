local builtin = require("telescope.builtin")
local api = vim.api

local M = {}

local BUF_NAME_MARK = "　➜ "

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

local function build_path(path, max_len)
    if #path > max_len then
        return "…"..path:sub(-max_len+1).."»"
    else
        return path.."»"
    end
end

local buildLinesForBuffers = function(max_width, max_height, exclude)
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

    local bufGroups = {}
    local dirs = {}
    for i, buf in ipairs(bufs) do
        local dir = string.match(vim.fs.normalize(buf.name), ".*/")
        if dir == nil then
            dir = "[No Name]"
        end
        if bufGroups[dir] == nil then
            bufGroups[dir] = {}
            dirs[#dirs + 1] = dir
        end
        local bg = bufGroups[dir]
        bg[#bg + 1] = buf
    end

    local bnr = vim.fn.bufnr('%')
    local lines = {""}
    local bufNrs = {}
    local markTotal = 0
    local height = 0
    for _, dir in ipairs(dirs) do
        lines[#lines + 1] = build_path(dir, max_width - 1)
        height = height + 1
        local files = "|"
        for i, buf in ipairs(bufGroups[dir]) do
            local name = string.match(vim.fs.normalize(buf.name), ".*/(.*)") 
            if name == nil then
                name = buf.name
            end
            if name == "" then
                name = first_non_empty_line(buf.bufnr)
            end
            if buf.bufnr == bnr then
                files = files.." "..BUF_NAME_MARK..name.."*|"
            else
                files = files.." "..BUF_NAME_MARK..name.." |"
            end
            markTotal = markTotal + 1
            bufNrs[#bufNrs + 1] = buf.bufnr
        end
        lines[#lines + 1] = files
        height = height + math.ceil(#files / max_width)
        if height >= max_height then
            break
        end
    end
    lines[#lines + 1] = ""
    return lines, bufNrs, markTotal
end

local setTitle = function(lines, width, title)
    local TITLE_MARK = string.rep("=", (width - #title) / 2 )
    lines[1] = TITLE_MARK..title..TITLE_MARK
end
local layout = function(lines, max_width)
    local width = 0
    for _, line in ipairs(lines) do
        if #line >= max_width then
            width = max_width
            break
        elseif #line > width then
            width = #line
        end
    end
    local height = 1
    for _, line in ipairs(lines) do
        height = height + math.ceil(#line / width)
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

local buildLinesForOldFiles = function(num, lineTotal, max_width)
    local bufs = vim.fn.getbufinfo { buflisted = true }
    local bufNames = {}
    for i, buf in ipairs(bufs) do
        bufNames[#bufNames + 1] = buf.name
    end

    local oldfiles = {}
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

    local groups = {}
    local dirs = {}
    for i, file in ipairs(oldfiles) do
        local dir = string.match(file, ".*/")
        if groups[dir] == nil then
            groups[dir] = {}
            dirs[#dirs + 1] = dir
        end
        local bg = groups[dir]
        bg[#bg + 1] = string.match(file, ".*/(.*)")
    end

    local lines = {""}
    local paths = {}
    local newLine = 1
    for _, dir in ipairs(dirs) do
        lines[#lines + 1] = build_path(dir, max_width - 1)
        newLine = newLine + 1
        local files = "|"
        for _, name in ipairs(groups[dir]) do
            files = files.." "..BUF_NAME_MARK..name.." |"
            paths[#paths + 1] = dir..name
        end
        lines[#lines + 1] = files
        newLine = newLine + math.ceil(#files / max_width)
        if newLine >= lineTotal - 1 then
            break
        end
    end
    lines[#lines + 1] = ""
    return lines, paths
end

local function bufDisplayName(bufnr)
    local name = api.nvim_buf_get_name(bufnr)
    local tail = string.match(vim.fs.normalize(name), ".*/(.*)")
    if tail == nil then
        tail = name
    end
    if tail == "" then
        tail = first_non_empty_line(bufnr)
    end
    return tail
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
local function layoutBlock(node, nr, cur_win)
    local kind = node[1]
    if kind == "leaf" then
        local win = node[2]
        local name = nr..":"..bufDisplayName(api.nvim_win_get_buf(win))
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
        children[#children+1] = layoutBlock(child, nr, cur_win)
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
local buildLinesForTabs = function()
    local tabs = api.nvim_list_tabpages()
    local cur_win = api.nvim_get_current_win()
    local cells = {}
    local rows, total = 0, 0
    for _, tab in ipairs(tabs) do
        local nr = api.nvim_tabpage_get_number(tab)
        local block = layoutBlock(vim.fn.winlayout(nr), nr, cur_win)
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
        local line = "|"
        for _, cell in ipairs(cells) do
            local l = cell.lines[r]
            line = line..padRight(l and l.text or "", cell.width).."|"
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
    local tabLines, tabData = buildLinesForTabs()
    local tabWidth, tabHeight = 0, 0
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
    local bufLines, bufData, bufTotal = buildLinesForBuffers(max_width, max_height - tabHeight, exclude)
    local bufWidth, bufHeight = 0, 0
    if bufTotal > 0 then
        bufWidth, bufHeight = layout(bufLines, max_width)
    end

    local width = math.max(tabWidth, bufWidth)
    local height = tabHeight + bufHeight
    local markTotal = #tabData + bufTotal

    local oldFileLines, oldFilePaths = {}, {}
    local max_marks = #(M.config.quick_buffer_characters)
    if markTotal < max_marks and height < max_height then
        oldFileLines, oldFilePaths = buildLinesForOldFiles(max_marks - markTotal, max_height - height, max_width)
        local w, h = layout(oldFileLines, max_width)
        width = math.max(width, w)
        height = height + h
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
            matches = buildMarks(bnr, buf_picker_ns, data)
        elseif ch == ESC then
            break
        else
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
