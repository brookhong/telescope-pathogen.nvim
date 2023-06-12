local actions = require("telescope.actions")
local builtin = require('telescope.builtin')
local config = require("telescope.config")
local finders = require("telescope.finders")
local previewers = require('telescope.previewers')
local state = require("telescope.actions.state")

local M = {
    use_last_search_for_live_grep = true,
    short_prompt_path = false
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
    return vim.fn.fnamemodify((vim.fs.normalize(dir)):gsub("(\\S*)/*$", "%1"), ":h")
end

local cwd_stack = {}
local previous_mode
local word_match = "-w"
local function common_mappings(prompt_bufnr, map)
    local function proceed_with_parent_dir(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        local cwd = curr_picker.prompt_prefix:gsub("> $", "")
        if get_parent_dir(cwd) == cwd then
            vim.notify("You are already under root.")
            return
        end
        table.insert(cwd_stack, cwd)
        reload_picker(curr_picker, prompt_bufnr, get_parent_dir(cwd))
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
        local cwd = curr_picker.prompt_prefix:gsub("> $", "")

        if previous_mode then
            if previous_mode == "browse_file" then
                M.browse_file({ cwd = cwd })
            else
                current_mode = previous_mode
                reload_picker(curr_picker, prompt_bufnr, cwd)
            end
            previous_mode = nil
        else
            if current_mode == "browse_file" then
                return
            else
                actions.close(prompt_bufnr)
                previous_mode = current_mode
                M.browse_file({ cwd = cwd, only_dir = true, prompt_title = "Browse directory" })
            end
        end
    end
    map("i", "<C-o>", proceed_with_parent_dir)
    map("i", "<C-l>", revert_back_last_dir)
    map("i", "<C-b>", change_working_directory)
    if current_mode == "grep_string" then
        local function toggle_word_match(prompt_bufnr)
            word_match = word_match == nil and "-w" or nil
            local curr_picker = state.get_current_picker(prompt_bufnr)
            local cwd = curr_picker.prompt_prefix:gsub("> $", "")
            local opts = {
                default_text = curr_picker:_get_prompt(),
                attach_mappings = curr_picker.attach_mappings,
                cwd = cwd,
                prompt_prefix = cwd .. "> ",
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
    local entry_display = require "telescope.pickers.entry_display"
    -- local cwd = opts.cwd or utils.capture("git rev-parse --show-toplevel", ture)
    local cwd = opts.cwd or vim.fs.normalize(vim.fn.getcwd())
    opts.prompt_title = opts.prompt_title or "Browse file"
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
    local displayer = entry_display.create {
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
                cwd = input:gsub("/$", "") .. "/"
                curr_picker:refresh(new_finder(cwd, "*"), { reset_prompt = true, new_prefix = cwd .. "> " })
            elseif vim.fn.isdirectory(input) == 1 then
                cwd = input:gsub("/+$", "")
                curr_picker:refresh(new_finder(cwd, "*"), { reset_prompt = true, new_prefix = cwd .. "> " })
            elseif string.match(input, "^[^/]+/.+") ~= nil then
                input = input:gsub("/", "*/") .. "*"
                curr_picker:refresh(new_finder(cwd, input), { reset_prompt = true, new_prefix = cwd .. "> " })
            elseif string.match(input, "/[^*]+*") ~= nil then
                local p = string.find(input, "/")
                cwd = input:sub(1, p)
                input = input:sub(p + 1)
                curr_picker:refresh(new_finder(cwd, input), { reset_prompt = true, new_prefix = cwd .. "> " })
            end
            return
        end
        if content.kind == "📁" then
            cwd = (cwd):sub(-1) ~= "/" and cwd .. "/" or cwd
            cwd = cwd .. content.value
            curr_picker:refresh(new_finder(cwd, "*"), { reset_prompt = true, new_prefix = cwd .. "> " })
        else
            actions.close(prompt_bufnr)
            vim.cmd("edit " .. cwd .. "/" .. content.value)
        end
    end
    local function edit_path(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        local cwd = curr_picker.prompt_prefix:gsub("> $", "")
        curr_picker:set_prompt(cwd)
    end
    local function find_files(prompt_bufnr)
        actions.close(prompt_bufnr)
        previous_mode = current_mode
        M.find_files({
            cwd = cwd
        })
    end
    local function live_grep(prompt_bufnr)
        actions.close(prompt_bufnr)
        previous_mode = current_mode
        M.live_grep({
            cwd = cwd
        })
    end
    local function create_file(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        local content = state.get_selected_entry(prompt_bufnr)
        if content ~= nil then
            local file_name = cwd .. "/" .. content.value
            vim.ui.input({ prompt = "Copy file: ", default = file_name }, function(input)
                if not input or input == file_name then
                    return
                end
                actions.close(prompt_bufnr)
                vim.loop.fs_copyfile(file_name, input)
                vim.cmd("edit " .. input)
            end)
        else
            local file_name = cwd .. "/" .. curr_picker:_get_prompt()
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
            vim.ui.input({ prompt = "Delete file: ", default = cwd .. "/" .. content.value }, function(input)
                if not input then
                    return
                end
                vim.fn.delete(input)
                curr_picker:reload(cwd)
            end)
        end
    end
    local function terminal(prompt_bufnr)
        actions.close(prompt_bufnr)
        vim.cmd("cd " .. cwd)
        vim.cmd("tabnew term://" .. (vim.g.SHELL == nil and "zsh" or vim.g.SHELL))
    end
    local picker = require("telescope.pickers").new(opts, {
        prompt_title = opts.prompt_title,
        prompt_prefix = cwd .. "> ",
        finder = new_finder(cwd, "*"),
        previewer = previewers.new_buffer_previewer {
            title = "File Preview",
            define_preview = function(self, entry, status)
                local p = cwd .. "/" .. entry.value
                if p == nil or p == "" then
                    return
                end
                config.values.buffer_previewer_maker(p, self.state.bufnr, {
                    bufname = self.state.bufname,
                    winid = self.state.winid,
                    preview = opts.preview,
                })
            end,
        },
        sorter = config.values.generic_sorter({}),
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
        cwd = new_cwd
        local previous_prompt = picker:_get_prompt(),
        picker:refresh(new_finder(cwd, "*"), { reset_prompt = true, new_prefix = cwd .. "> " })
        picker:set_prompt(previous_prompt)
    end
    picker:find()
end

local function start_builtin(opts)
    opts = opts or {}
    local cwd = opts.cwd or vim.loop.cwd()
    opts.cwd = M.short_prompt_path and vim.fn.fnamemodify(cwd, ":~") or cwd
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

return M
