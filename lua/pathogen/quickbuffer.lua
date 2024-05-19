local builtin = require("telescope.builtin")
local api = vim.api

local M = {}

local BUF_NAME_MARK = "　➜ "

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

local buildLinesForBuffers = function(max_width)
    local bufs = vim.fn.getbufinfo { buflisted = true }
    if #bufs == 1 then
        return {}, {}, 0
    end
    table.sort(bufs, function(a, b)
        return a.name < b.name
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

    table.sort(dirs)
    local bnr = vim.fn.bufnr('%')
    local lines = {""}
    local bufNrs = {}
    local markTotal = 0
    for _, dir in ipairs(dirs) do
        lines[#lines + 1] = build_path(dir, max_width - 1)
        local files = "|"
        for i, buf in ipairs(bufGroups[dir]) do
            local name = string.match(vim.fs.normalize(buf.name), ".*/(.*)")
            if name == nil then
                name = buf.name
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
            if #oldfiles > num then
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

local buf_picker_id = vim.api.nvim_create_buf(false, true)
vim.bo[buf_picker_id].filetype = "quickbuffer"
local buf_picker_ns = api.nvim_create_namespace('quick_buffer')
local BS = vim.api.nvim_replace_termcodes("<BS>", true, true, true)
local ESC = vim.api.nvim_replace_termcodes("<Esc>", true, true, true)
function M.quickBuffers(config)
    -- build buffer names
    local max_width = vim.api.nvim_win_get_width(0)
    local lines, data, markTotal = buildLinesForBuffers(max_width)
    local width, height = layout(lines, max_width)
    if markTotal > 0 then
        setTitle(lines, width, "Buffers")
    end
    local max_height = vim.api.nvim_win_get_height(0) - 1
    local max_marks = #(M.config.quick_buffer_characters)
    if markTotal < max_marks and height < max_height then
        local oldFileLines, oldFilePaths = buildLinesForOldFiles(max_marks - #data, max_height - height, max_width)
        local w, h = layout(oldFileLines, max_width)
        if w > width then
            width = w
            setTitle(lines, width, "Buffers")
        end
        setTitle(oldFileLines, width, "Old files")
        for _, f in ipairs(oldFileLines) do
            lines[#lines+1] = f
        end
        for _, n in ipairs(oldFilePaths) do
            data[#data+1] = n
        end
        height = height + h
    end

    -- show buffer picker
    local original_win_id = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(buf_picker_id, 0, -1, true, lines)
    local buf_picker_win_id = vim.api.nvim_open_win(buf_picker_id, false, {relative='win', row=0, col=0, width=width, height=height + 2})
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

    vim.api.nvim_win_close(buf_picker_win_id , true)
    vim.api.nvim_set_current_win(original_win_id)
    if #matches == 1 then
        local data = matches[1].data
        if type(data) == "number" then
            vim.cmd(string.format("b %d", data))
        else
            vim.cmd(string.format("e %s", data))
        end
    elseif ch ~= ESC then
        builtin.oldfiles()
    end
end

return M
