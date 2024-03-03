local Path = require("plenary.path")
local builtin = require("telescope.builtin")
local conf = require("telescope.config").values
local finders = require("telescope.finders")
local log = require("telescope.log")
local make_entry = require("telescope.make_entry")
local pickers = require("telescope.pickers")
local popup = require("plenary.popup")
local sorters = require("telescope.sorters")
local state = require("telescope.actions.state")
local telescope_actions = require("telescope.actions")

local flatten = vim.tbl_flatten

local M = {
    config = {
        attach_mappings = function(map, actions)
            map("i", "<C-o>", actions.proceed_with_parent_dir)
            map("i", "<C-l>", actions.revert_back_last_dir)
            map("i", "<C-b>", actions.change_working_directory)
            map("i", "<C-g>g", actions.grep_in_result)
            map("i", "<C-g>i", actions.invert_grep_in_result)
        end,
        use_last_search_for_live_grep = true,
        prompt_prefix_length = 100
    }
}

local unescape_chars = function(str)
    return string.gsub(str, "\\", "")
end

local orig_new_oneshot_job = finders.new_oneshot_job
local __last_search
finders.new_oneshot_job = function(args, opts)
    __last_search = unescape_chars(args[#args])
    return orig_new_oneshot_job(args, opts)
end

function build_prompt_prefix(path)
    if #path > M.config.prompt_prefix_length then
        return "…"..path:sub(-M.config.prompt_prefix_length).."» "
    else
        return path.."» "
    end
end

local current_mode
local word_match = "-w"
local reusable_opts = {}
local function reload_picker(curr_picker, prompt_bufnr, cwd)
    if current_mode == "browse_file" then
        return curr_picker:reload(cwd)
    end
    local opts = {
        default_text = curr_picker:_get_prompt(),
        attach_mappings = curr_picker.attach_mappings,
        cwd = cwd,
        prompt_prefix = build_prompt_prefix(cwd),
    }
    if current_mode == "grep_string" then
        opts.search = __last_search
        opts.word_match = word_match
        opts.results_title = word_match == nil and "Results" or "Results with exact word matches"
    end
    for k,v in pairs(reusable_opts) do
        opts[k] = v
    end
    telescope_actions.close(prompt_bufnr)
    builtin[current_mode](opts)
end
local function get_parent_dir(dir)
    if dir == "" or dir == "/" or string.match(dir, "^[A-z]:/$") ~= nil then
        return dir
    end
    return vim.fn.fnamemodify(vim.fs.normalize(dir), ":h")
end

local function grep_in_result_impl(prompt_bufnr, kind, sorter)
    local picker = state.get_current_picker(prompt_bufnr)
    local results = {}
    for entry in picker.manager:iter() do
        if entry[1] then
            results[#results + 1] = entry[1]
        elseif entry.filename and entry.lnum and entry.col and entry.text then
            results[#results + 1] = string.format("%s:%d:%d:%s", entry.filename, entry.lnum, entry.col, entry.text)
        else
            log.error("invalid entry:", vim.inspect(entry))
        end
    end
    if #results < 2 then
        return
    end

    local prompt_title = picker.prompt_title
    local entry_maker
    if string.match(prompt_title, '^Browse file$') ~= nil then
        entry_maker = gen_from_file_browser(picker.cwd)
    elseif string.match(prompt_title, '^Find Files$') ~= nil then
        entry_maker = make_entry.gen_from_file({ cwd = picker.cwd })
    else
        entry_maker = make_entry.gen_from_vimgrep({ cwd = picker.cwd })
    end
    local new_finder = function()
        return finders.new_table({
            results = results,
            entry_maker = entry_maker
        })
    end

    local new_prompt_title = ""
    local last_kind = prompt_title:sub(-1)
    if last_kind == "+" or last_kind == "-" then
        if picker:_get_prompt() == "" then
            return
        else
            new_prompt_title = prompt_title .. picker:_get_prompt() .. " " .. kind
        end
    else
        new_prompt_title = prompt_title .. " : " .. picker:_get_prompt() .. " " .. kind
    end

    -- print("picker", vim.inspect(picker))
    local new_picker = pickers.new({ cwd = picker.cwd }, {
        prompt_title = new_prompt_title,
        finder = new_finder(),
        previewer = picker.previewer,
        sorter = sorter,
        attach_mappings = function(prompt_bufnr, map)
            picker.attach_mappings(prompt_bufnr, map)
            -- vim.keymap.del('i', "<C-b>", { buffer = prompt_bufnr })
            map("i", "<C-b>", function()
                -- ~/.local/share/nvim/lazy/telescope.nvim/lua/telescope/pickers.lua:1330
                -- keep status_updater work
                picker.closed = nil
                picker:find()
            end)
            return true
        end,
    })
    new_picker:find()
end

local cwd_stack = {}
local previous_mode
local local_actions = {
    proceed_with_parent_dir = function(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        if get_parent_dir(curr_picker.cwd) == curr_picker.cwd then
            vim.notify("You are already under root.")
            return
        end
        table.insert(cwd_stack, curr_picker.cwd)
        reload_picker(curr_picker, prompt_bufnr, get_parent_dir(curr_picker.cwd))
    end,
    revert_back_last_dir = function(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        if #cwd_stack == 0 then
            return
        end
        reload_picker(curr_picker, prompt_bufnr, table.remove(cwd_stack, #cwd_stack))
    end,
    change_working_directory = function(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)

        if previous_mode then
            if previous_mode == "browse_file" then
                M.browse_file({ cwd = curr_picker.cwd })
            else
                current_mode = previous_mode
                reload_picker(curr_picker, prompt_bufnr, curr_picker.cwd)
            end
            previous_mode = nil
        else
            if current_mode == "browse_file" then
                return
            else
                telescope_actions.close(prompt_bufnr)
                previous_mode = current_mode
                M.browse_file({ cwd = curr_picker.cwd, only_dir = true, prompt_title = "Browse directory" })
            end
        end
    end,
    grep_in_result = function(prompt_bufnr)
        grep_in_result_impl(prompt_bufnr, "+", sorters.get_substr_matcher())
    end,
    invert_grep_in_result = function(prompt_bufnr)
        grep_in_result_impl(prompt_bufnr, "-", sorters.Sorter:new {
            discard = false,

            scoring_function = function(_, prompt, line)
                if prompt ~= "" and string.find(line, prompt) then
                    return -1
                end
                return 1
            end,
        })
    end,
}

local function common_mappings(prompt_bufnr, map)
    M.config.attach_mappings(map, local_actions)
    if current_mode == "grep_string" then
        local function toggle_word_match(prompt_bufnr)
            word_match = word_match == nil and "-w" or nil
            local curr_picker = state.get_current_picker(prompt_bufnr)
            local opts = {
                default_text = curr_picker:_get_prompt(),
                attach_mappings = curr_picker.attach_mappings,
                cwd = curr_picker.cwd,
                prompt_prefix = build_prompt_prefix(curr_picker.cwd),
                results_title = word_match == nil and "Results" or "Results with exact word matches",
                word_match = word_match,
                search = __last_search
            }
            telescope_actions.close(prompt_bufnr)
            builtin.grep_string(opts)
        end
        map("i", "<C-y>", toggle_word_match)
    end
    return true
end

local lookup_keys = {
    ordinal = 1,
    value = 1,
}
local displayer = require("telescope.pickers.entry_display").create {
    separator = " ",
    items = {
        { width = 2 },
        { width = 31 },
        { remaining = true },
    },
}
function gen_from_file_browser(cwd)
    local mt_file_entry = {}

    mt_file_entry.cwd = cwd
    mt_file_entry.display = function(entry)
        return displayer {
            entry.kind,
            { entry.mtime, "TelescopePreviewDate" },
            { entry.value, entry.kind == "📁" and "Directory" or "" },
        }
    end

    mt_file_entry.__index = function(t, k)
        local raw = rawget(mt_file_entry, k)
        if raw then
            return raw
        end

        if k == "kind" then
            local fp = Path:new({ cwd, rawget(t, 1) }):absolute()
            return vim.fn.isdirectory(fp) == 1 and "📁" or " "
        elseif k == "mtime" then
            local fp = Path:new({ cwd, rawget(t, 1) }):absolute()
            return vim.fn.strftime("%c", vim.fn.getftime(fp))
        elseif k == "path" then
            local fp = Path:new({ cwd, rawget(t, 1) }):absolute()
            return fp
        end
        return rawget(t, rawget(lookup_keys, k))
    end

    return function(line)
        return setmetatable({ line }, mt_file_entry)
    end
end

function M.find_project_root()
    for _, m in ipairs({ '.git' }) do
        local root = vim.fn.finddir(m, vim.fn.expand('%:p:h')..';')
        if root ~= "" then
            root = vim.fs.normalize(root)
            root = root:gsub("/[^/]*$", "")
            return root
        end
    end
    for _, m in ipairs({ '.git', '.gitignore' }) do
        local root = vim.fn.findfile(m, vim.fn.expand('%:p:h')..';')
        if root ~= "" then
            root = root:gsub("/[^/]*$", "")
            return root
        end
    end
end
function M.browse_file(opts)
    current_mode = "browse_file"
    opts.prompt_title = opts.prompt_title or "Browse file"
    opts.cwd = opts.cwd or vim.fs.normalize(vim.fn.getcwd())
    local ls1 = function(path, pattern)
        local t = {}
        local content = vim.fn.globpath(path, pattern, false, true)
        if pattern == "*" then
            for _, f in ipairs(vim.fn.globpath(path, ".[^.]*", false, true)) do
                content[#content + 1] = f
            end
        end
        for _, f in ipairs(content) do
            local offset = string.len(path) + 2
            if path == "/" then
                offset = 2
            elseif string.match(path, ":/$") ~= nil then
                offset = 4
            end
            table.insert(t, {
                value = string.sub(vim.fs.normalize(f), offset),
                mtime = vim.fn.getftime(f)
            })
        end
        table.sort(t, function(a, b) return a.mtime > b.mtime end)
        content = t
        t = {}
        for _, e in ipairs(content) do
            table.insert(t, e.value)
        end
        return t
    end
    local new_finder = function(cwd, pattern)
        return finders.new_table({
            results = ls1(cwd, pattern),
            entry_maker = gen_from_file_browser(cwd)
        })
    end
    local pickit = function(prompt_bufnr)
        local content = state.get_selected_entry(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        if content == nil then
            local input = curr_picker:_get_prompt()
            -- avoid long run from **
            input = input:gsub("%*%*", "*")
            input = vim.fs.normalize(input)

            if vim.fn.filereadable(input) == 1 then
                telescope_actions.close(prompt_bufnr)
                vim.cmd("edit " .. input)
            elseif string.match(input, '^[A-z]:/?$') ~= nil then
                curr_picker.cwd = input:gsub("/$", "") .. "/"
                curr_picker:refresh(new_finder(curr_picker.cwd, "*"), { reset_prompt = true, new_prefix = build_prompt_prefix(curr_picker.cwd) })
            elseif vim.fn.isdirectory(input) == 1 then
                curr_picker.cwd = input:gsub("/+$", "")
                curr_picker:refresh(new_finder(curr_picker.cwd, "*"), { reset_prompt = true, new_prefix = build_prompt_prefix(curr_picker.cwd) })
            elseif string.match(input, "^[^/]+/.+") ~= nil then
                input = input:gsub("/", "*/") .. "*"
                curr_picker:refresh(new_finder(curr_picker.cwd, input), { reset_prompt = true, new_prefix = build_prompt_prefix(curr_picker.cwd) })
            elseif string.match(input, "/[^*]+*") ~= nil then
                local p = string.find(input, "/")
                curr_picker.cwd = input:sub(1, p)
                input = input:sub(p + 1)
                curr_picker:refresh(new_finder(curr_picker.cwd, input), { reset_prompt = true, new_prefix = build_prompt_prefix(curr_picker.cwd) })
            end
            return
        end
        if content.kind == "📁" then
            local cwd = curr_picker.cwd
            cwd = (cwd):sub(-1) ~= "/" and cwd .. "/" or cwd
            cwd = cwd .. content.value
            curr_picker:refresh(new_finder(cwd, "*"), { reset_prompt = true, new_prefix = build_prompt_prefix(cwd) })
            curr_picker.cwd = cwd
        else
            telescope_actions.close(prompt_bufnr)
            vim.cmd("edit " .. curr_picker.cwd .. "/" .. content.value)
        end
    end
    local function edit_path(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        curr_picker:set_prompt(curr_picker.cwd)
    end
    local function find_files(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        telescope_actions.close(prompt_bufnr)
        previous_mode = current_mode
        M.find_files({
            cwd = curr_picker.cwd
        })
    end
    local function live_grep(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        telescope_actions.close(prompt_bufnr)
        previous_mode = current_mode
        M.live_grep({
            cwd = curr_picker.cwd
        })
    end
    local function create_file(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        local content = state.get_selected_entry(prompt_bufnr)
        if content ~= nil then
            local file_name = curr_picker.cwd .. "/" .. content.value
            vim.ui.input({ prompt = "Copy file: ", default = file_name }, function(input)
                if not input or input == file_name then
                    return
                end
                telescope_actions.close(prompt_bufnr)
                vim.loop.fs_copyfile(file_name, input)
                vim.cmd("edit " .. input)
            end)
        else
            local file_name = curr_picker.cwd .. "/" .. curr_picker:_get_prompt()
            vim.ui.input({ prompt = "Create file: ", default = file_name }, function(input)
                if not input then
                    return
                end
                telescope_actions.close(prompt_bufnr)
                vim.loop.fs_open(input, "w", 438)
                vim.cmd("edit " .. input)
            end)
        end
    end
    local function delete_file(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        local content = state.get_selected_entry(prompt_bufnr)
        if content ~= nil then
            vim.ui.input({ prompt = "Delete file: ", default = curr_picker.cwd .. "/" .. content.value }, function(input)
                if not input then
                    return
                end
                vim.fn.delete(input)
                curr_picker:reload(curr_picker.cwd)
            end)
        end
    end
    local function terminal(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        telescope_actions.close(prompt_bufnr)
        vim.cmd("cd " .. curr_picker.cwd)
        vim.cmd("tabnew term://" .. (vim.g.SHELL == nil and "zsh" or vim.g.SHELL))
    end
    local function goto_project_root(prompt_bufnr)
        local root = M.find_project_root()
        if root ~= nil and root ~= "" then
            local curr_picker = state.get_current_picker(prompt_bufnr)
            curr_picker:reload(root)
        end
    end
    local picker = pickers.new(opts, {
        prompt_title = opts.prompt_title,
        prompt_prefix = build_prompt_prefix(opts.cwd),
        finder = new_finder(opts.cwd, "*"),
        previewer = conf.file_previewer(opts),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(_, map)
            map("i", "<CR>", pickit)
            map("i", "<Tab>", pickit)
            map("i", ",", edit_path)
            map("i", "<C-]>", goto_project_root)
            map("i", "<C-e>", live_grep)
            map("i", "<C-f>", find_files)
            map("i", "<C-g>c", create_file)
            map("i", "<C-g>d", delete_file)
            map("i", "<C-g>t", terminal)
            return common_mappings(_, map)
        end,
    })
    picker.reload = function(_, new_cwd)
        picker.cwd = new_cwd
        local previous_prompt = picker:_get_prompt(),
        picker:refresh(new_finder(new_cwd, "*"), { reset_prompt = true, new_prefix = build_prompt_prefix(new_cwd) })
        picker:set_prompt(previous_prompt)
    end
    picker:find()
end

local function start_builtin(opts)
    opts = opts or {}
    opts.cwd = opts.cwd or vim.loop.cwd()
    opts.prompt_prefix = build_prompt_prefix(opts.cwd)
    opts.attach_mappings = opts.attach_mappings or common_mappings

    if opts.additional_args then
        reusable_opts.additional_args = opts.additional_args
    end
    builtin[current_mode](opts)
end

function M.grep_string(opts)
    current_mode = "grep_string"
    opts = opts or {}
    opts.word_match = word_match
    opts.results_title = word_match == nil and "Results" or "Results with exact word matches"
    start_builtin(opts)
end

function M.find_files(opts)
    current_mode = "find_files"
    start_builtin(opts)
end

function M.live_grep(opts)
    current_mode = "live_grep"
    opts = opts or {}
    if M.config.use_last_search_for_live_grep then
        opts.default_text = vim.fn.getreg("/"):gsub("\\<([^\\]+)\\>", "%1")
    end
    start_builtin(opts)
end

local function grep_in_files(opts)
    opts.cwd = opts.cwd and vim.fn.expand(opts.cwd) or vim.loop.cwd()

    local live_grepper = finders.new_job(function(prompt)
        if not prompt or prompt == "" then
            return nil
        end

        return flatten { conf.vimgrep_arguments, "--", prompt, opts.search_list }
    end, make_entry.gen_from_vimgrep(opts), opts.max_results, opts.cwd)

    pickers.new(opts, {
        prompt_title = "Live Grep in specified files",
        finder = live_grepper,
        previewer = conf.grep_previewer(opts),
        -- TODO: It would be cool to use `--json` output for this
        -- and then we could get the highlight positions directly.
        sorter = sorters.highlighter_only(opts),
    })
    :find()
end

local function unique(a)
    local hash = {}
    local res = {}
    hash[""] = true -- prevent empty line
    for _,v in ipairs(a) do
        if (not hash[v]) then
            res[#res+1] = v
            hash[v] = true
        end
    end
    return res
end

function M.edit_in_popup(title, lines, opts)
    opts = opts or {}
    local p_height = vim.api.nvim_win_get_height(0)
    local p_width = vim.api.nvim_win_get_width(0)
    local height = p_height > 20 and 20 or p_height
    local width = p_width > 120 and 120 or p_width
    local maxheight = p_height - 6
    maxheight = maxheight > height and maxheight or height
    local maxwidth = p_width - 6
    maxwidth = maxwidth > width and maxwidth or width
    local win_id = popup.create(lines, {
        minheight = height,
        width = width,
        maxheight = maxheight,
        maxwidth = maxwidth,
        border = true,
        title = title,
        highlight = "PopupColor",
        finalize_callback = function(win_id, bufnr)
            vim.fn.execute(":set relativenumber")
        end
    })
    local popup_bufnr = vim.api.nvim_win_get_buf(win_id)
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = popup_bufnr,
        nested = true,
        once = true,
        callback = function()
            vim.api.nvim_win_close(win_id, true)
        end,
    })

    local bufopts = { noremap=true, silent=true, buffer=popup_bufnr }
    local function popup_buf_map(mode, key, fn)
        vim.keymap.set(mode, key, fn, bufopts)
    end
    popup_buf_map("n", "<c-c>", function()
        vim.api.nvim_win_close(win_id, true)
    end)
    popup_buf_map("n", "<CR>", function()
        local new_list = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        vim.api.nvim_win_close(win_id, true)
        if opts.exit then
            opts.exit(new_list)
        end
    end)
    if opts.attach then
        opts.attach(popup_buf_map)
    end
end

local function edit_qflist(type)
    local loc_list = {}
    local items = type == "location" and vim.fn.getloclist(0) or vim.fn.getqflist()
    if #items == 0 then
        print(string.format("%s list is empty.", type))
        return
    end
    for _, data in ipairs(items) do
        loc_list[#loc_list + 1] = string.format("%s:%d:%d:%s", vim.fn.bufname(data['bufnr']), data.lnum, data.col, data.text)
    end

    local title = string.format("Edit %s list, <CR> to write, <c-c> to abort.", type)
    M.edit_in_popup(title, loc_list, {
        exit = function(new_list)
            vim.g._lgetexpr_lines = new_list
            vim.fn.execute(string.format(":%sgetexpr g:_lgetexpr_lines", type == "location" and "l" or "c"))
            vim.g._lgetexpr_lines = nil
        end
    })
end

function M.edit_loclist()
    edit_qflist("location")
end

function M.edit_qflist()
    edit_qflist("qf")
end

local function launch_search_list_editor()
    local search_list = {}
    local file_list_cache = vim.fn.stdpath('cache') .. '/telescope-pathogen.search_list'
    if vim.fn.filereadable(file_list_cache) == 1 then
        search_list = vim.fn.readfile(file_list_cache)
    end

    local title = "Edit the file list to search, with one file each line, <CR> to continue, <c-c> to abort."
    M.edit_in_popup(title, search_list, {
        attach = function(popup_buf_map)
            popup_buf_map("n", "<CR>", function()
                vim.cmd("%s/|\\d\\+ .*//e")
                search_list = unique(vim.api.nvim_buf_get_lines(0, 0, -1, false))
                vim.fn.writefile(search_list, file_list_cache)
                grep_in_files({
                    search_list = search_list
                })
            end)
        end
    })
end

function M.grep_in_files(opts)
    launch_search_list_editor()
end

return M
