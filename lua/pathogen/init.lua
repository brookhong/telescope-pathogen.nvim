local actions = require("telescope.actions")
local builtin = require("telescope.builtin")
local conf = require("telescope.config").values
local finders = require("telescope.finders")
local state = require("telescope.actions.state")
local pickers = require("telescope.pickers")
local sorters = require("telescope.sorters")
local make_entry = require("telescope.make_entry")
local popup = require("plenary.popup")
local flatten = vim.tbl_flatten

local M = {
    use_last_search_for_live_grep = true
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

local current_mode
local function reload_picker(curr_picker, prompt_bufnr, cwd)
    if current_mode == "browse_file" then
        return curr_picker:reload(cwd)
    end
    local opts = {
        default_text = curr_picker:_get_prompt(),
        attach_mappings = curr_picker.attach_mappings,
        cwd = cwd,
        prompt_prefix = cwd .. "> ",
    }
    if current_mode == "grep_string" then
        opts.search = __last_search
    end
    actions.close(prompt_bufnr)
    builtin[current_mode](opts)
end
local function get_parent_dir(dir)
    if dir == "" or dir == "/" or string.match(dir, "^[A-z]:/$") ~= nil then
        return dir
    end
    return vim.fn.fnamemodify((vim.fs.normalize(dir)):gsub("(\\S*)/*$", "%1"), ":h")
end

local cwd_stack = {}
local previous_mode
local word_match = "-w"
local function common_mappings(prompt_bufnr, map)
    local function proceed_with_parent_dir(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        if get_parent_dir(curr_picker.cwd) == curr_picker.cwd then
            vim.notify("You are already under root.")
            return
        end
        table.insert(cwd_stack, curr_picker.cwd)
        reload_picker(curr_picker, prompt_bufnr, get_parent_dir(curr_picker.cwd))
    end
    local function revert_back_last_dir(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        if #cwd_stack == 0 then
            return
        end
        reload_picker(curr_picker, prompt_bufnr, table.remove(cwd_stack, #cwd_stack))
    end
    local function change_working_directory(prompt_bufnr)
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
                actions.close(prompt_bufnr)
                previous_mode = current_mode
                M.browse_file({ cwd = curr_picker.cwd, only_dir = true, prompt_title = "Browse directory" })
            end
        end
    end
    local function grep_in_result_impl(prompt_bufnr, kind, sorter)
        local picker = state.get_current_picker(prompt_bufnr)
        local results = {}
        for entry in picker.manager:iter() do
            results[#results + 1] = entry[1]
        end
        if #results < 2 then
            return
        end

        local new_finder = function()
            return finders.new_table({
                results = results,
                entry_maker = make_entry.gen_from_vimgrep({ cwd = picker.cwd })
            })
        end

        local prompt_title = picker.prompt_title
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
                    picker:find()
                end)
                return true
            end,
        })
        new_picker:find()
    end
    local function grep_in_result(prompt_bufnr)
        grep_in_result_impl(prompt_bufnr, "+", sorters.get_substr_matcher())
    end
    local function invert_grep_in_result(prompt_bufnr)
        grep_in_result_impl(prompt_bufnr, "-", sorters.Sorter:new {
            discard = false,

            scoring_function = function(_, prompt, line)
                if prompt ~= "" and string.find(line, prompt) then
                    return -1
                end
                return 1
            end,
        })
    end
    map("i", "<C-o>", proceed_with_parent_dir)
    map("i", "<C-l>", revert_back_last_dir)
    map("i", "<C-b>", change_working_directory)
    map("i", "<C-1>", grep_in_result)
    map("i", "<C-0>", invert_grep_in_result)
    if current_mode == "grep_string" then
        local function toggle_word_match(prompt_bufnr)
            word_match = word_match == nil and "-w" or nil
            local curr_picker = state.get_current_picker(prompt_bufnr)
            local opts = {
                default_text = curr_picker:_get_prompt(),
                attach_mappings = curr_picker.attach_mappings,
                cwd = curr_picker.cwd,
                prompt_prefix = curr_picker.cwd .. "> ",
                results_title = word_match == nil and "Results" or "Results with exact word matches",
                word_match = word_match,
                search = __last_search
            }
            actions.close(prompt_bufnr)
            builtin.grep_string(opts)
        end
        map("i", "<C-y>", toggle_word_match)
    end
    return true
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
                mtime = vim.fn.getftime(f),
                kind = vim.fn.isdirectory(f) == 1 and "📁" or " "
            })
        end
        table.sort(t, function(a, b) return a.mtime > b.mtime end)
        return t
    end
    local displayer = require("telescope.pickers.entry_display").create {
        separator = " ",
        items = {
            { width = 2 },
            { width = 31 },
            { remaining = true },
        },
    }
    local new_finder = function(cwd, pattern)
        return finders.new_table({
            results = ls1(cwd, pattern),
            entry_maker = function(entry)
                return {
                    ordinal = entry.value .. (entry.kind == "📁" and "/" or ""),
                    value = entry.value,
                    mtime = vim.fn.strftime("%c", entry.mtime),
                    kind = entry.kind,
                    path = cwd .. "/" .. entry.value, -- for default actions like select_horizontal
                    display = function(entry)
                        return displayer {
                            entry.kind,
                            { entry.mtime, "TelescopePreviewDate" },
                            { entry.value, entry.kind == "📁" and "Directory" or "" },
                        }
                    end,
                }
            end
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
                actions.close(prompt_bufnr)
                vim.cmd("edit " .. input)
            elseif string.match(input, '^[A-z]:/?$') ~= nil then
                curr_picker.cwd = input:gsub("/$", "") .. "/"
                curr_picker:refresh(new_finder(curr_picker.cwd, "*"), { reset_prompt = true, new_prefix = curr_picker.cwd .. "> " })
            elseif vim.fn.isdirectory(input) == 1 then
                curr_picker.cwd = input:gsub("/+$", "")
                curr_picker:refresh(new_finder(curr_picker.cwd, "*"), { reset_prompt = true, new_prefix = curr_picker.cwd .. "> " })
            elseif string.match(input, "^[^/]+/.+") ~= nil then
                input = input:gsub("/", "*/") .. "*"
                curr_picker:refresh(new_finder(curr_picker.cwd, input), { reset_prompt = true, new_prefix = curr_picker.cwd .. "> " })
            elseif string.match(input, "/[^*]+*") ~= nil then
                local p = string.find(input, "/")
                curr_picker.cwd = input:sub(1, p)
                input = input:sub(p + 1)
                curr_picker:refresh(new_finder(curr_picker.cwd, input), { reset_prompt = true, new_prefix = curr_picker.cwd .. "> " })
            end
            return
        end
        if content.kind == "📁" then
            local cwd = curr_picker.cwd
            cwd = (cwd):sub(-1) ~= "/" and cwd .. "/" or cwd
            cwd = cwd .. content.value
            curr_picker:refresh(new_finder(cwd, "*"), { reset_prompt = true, new_prefix = cwd .. "> " })
            curr_picker.cwd = cwd
        else
            actions.close(prompt_bufnr)
            vim.cmd("edit " .. curr_picker.cwd .. "/" .. content.value)
        end
    end
    local function edit_path(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        curr_picker:set_prompt(curr_picker.cwd)
    end
    local function find_files(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        actions.close(prompt_bufnr)
        previous_mode = current_mode
        M.find_files({
            cwd = curr_picker.cwd
        })
    end
    local function live_grep(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        actions.close(prompt_bufnr)
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
                actions.close(prompt_bufnr)
                vim.loop.fs_copyfile(file_name, input)
                vim.cmd("edit " .. input)
            end)
        else
            local file_name = curr_picker.cwd .. "/" .. curr_picker:_get_prompt()
            vim.ui.input({ prompt = "Create file: ", default = file_name }, function(input)
                if not input then
                    return
                end
                actions.close(prompt_bufnr)
                vim.loop.fs_open(input, "w", 644)
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
        actions.close(prompt_bufnr)
        vim.cmd("cd " .. curr_picker.cwd)
        vim.cmd("tabnew term://" .. (vim.g.SHELL == nil and "zsh" or vim.g.SHELL))
    end
    local picker = pickers.new(opts, {
        prompt_title = opts.prompt_title,
        prompt_prefix = opts.cwd .. "> ",
        finder = new_finder(opts.cwd, "*"),
        previewer = conf.file_previewer(opts),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(_, map)
            -- vim.fn.iunmap
            map("i", "<CR>", pickit)
            map("i", "<Tab>", pickit)
            map("i", ",", edit_path)
            map("i", "<C-e>", live_grep)
            map("i", "<C-f>", find_files)
            map("i", "<A-c>", create_file)
            map("i", "<A-d>", delete_file)
            map("i", "<A-t>", terminal)
            return common_mappings(_, map)
        end,
    })
    picker.reload = function(_, new_cwd)
        picker.cwd = new_cwd
        local previous_prompt = picker:_get_prompt(),
        picker:refresh(new_finder(new_cwd, "*"), { reset_prompt = true, new_prefix = new_cwd .. "> " })
        picker:set_prompt(previous_prompt)
    end
    picker:find()
end

local function start_builtin(opts)
    opts = opts or {}
    opts.cwd = opts.cwd or vim.loop.cwd()
    opts.prompt_prefix = opts.cwd .. "> "
    opts.attach_mappings = opts.attach_mappings or common_mappings
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
    if M.use_last_search_for_live_grep then
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
        attach_mappings = function(_, map)
            map("i", "<c-space>", actions.to_fuzzy_refine)
            return true
        end,
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

local function launch_search_list_editor(search_list)
    local search_list = {}
    local file_list_cache = vim.fn.stdpath('cache') .. '/telescope-pathogen.search_list'
    if vim.fn.filereadable(file_list_cache) == 1 then
        search_list = vim.fn.readfile(file_list_cache)
    end

    local win_id = popup.create(search_list, {
        minheight = 20,
        maxheight = 20,
        width = 120,
        border = true,
        title = "Edit the file list to search, with one file each line, <CR> to continue, <c-c> to abort.",
        highlight = "PopupColor",
    })
    local search_list_bufnr = vim.api.nvim_win_get_buf(win_id)
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = search_list_bufnr,
        nested = true,
        once = true,
        callback = function()
            -- vim.api.nvim_buf_delete(search_list_bufnr, { force = true })
            vim.api.nvim_win_close(win_id, true)
        end,
    })

    local bufopts = { noremap=true, silent=true, buffer=search_list_bufnr }
    vim.keymap.set("n", "<CR>", function()
        vim.cmd("%s/|\\d\\+ .*//e")
        search_list = unique(vim.api.nvim_buf_get_lines(0, 0, -1, false))
        vim.fn.writefile(search_list, file_list_cache)
        grep_in_files({
            search_list = search_list
        })
    end, bufopts)
    vim.keymap.set("n", "<c-c>", function()
        vim.api.nvim_win_close(win_id, true)
    end, bufopts)
end

function M.grep_in_files(opts)
    launch_search_list_editor()
end

return M
