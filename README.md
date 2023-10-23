# ✨ telescope-pathogen.nvim

**telescope-pathogen.nvim** is a telescope extension to help you to navigate through different path when using builtin actions from telescope such as `grep_string`, `find_files` and `live_grep`.

## ⚡️ Usage scenarios

* builtin action `grep_string` searches string(word under cursor or visual selection) within current working directory. If there is nothing found for what you want, and you want to search the same string within parent directory, you need close the ui and launch another `grep_string` with parent directory specified in `cwd`. With `pathogen grep_string` from this extension, to press `C-o` to search within an *o*uter directory(aka the parent different) for the same string, you can press `C-o` again and again until it reaches at the right ancestor directory. Press `C-l` to revert back to the *l*ast directory.

![a](https://user-images.githubusercontent.com/288207/225836008-a4b076a2-b81a-4208-9db7-b469e65040c1.gif)

* a worse case is that there is nothing found for what you want along the path from current working directory to the ancestor directory you picked. You want to search it within sibling folders or grand sibling folders(not sure if you can understand what I mean, maybe there is a better term to describe it), press `C-b` to call out the file *b*rowser to choose a directory.

* the same for `find_files` and `live_grep`.

![b](https://user-images.githubusercontent.com/288207/225836119-b4dd576b-2489-47d7-a891-a1344df6c54d.gif)

![c](https://user-images.githubusercontent.com/288207/225836208-fb5bf2cc-5c08-40ff-8bb1-0d62375315c6.gif)


* consider to use builtin action `find_files` to locate a file that you have its path(or partly) in a directory with millions of files or directories, you cannot quickly locate your target file though the telescope ui is considerably smooth. `pathogen browse_file` is for the case, with which you can pick up it by entering the path level by level. Or at least, you can use `C-f` to trigger `find_files` in a deeper directory which will have less files. If the directory is still too large to have your file be found by `find_files`, press `C-b` to bring back file *b*rowser to navigate manually or enter another deeper directory to `C-f`.

* `C-y` in the popup for `grep_string` to toggle exact word matches.

* `grep_in_files` helps to grep a string in a specified file list. It will launch a popup first for you to edit the file list, then `<Cr>` to continue with same UI as `live_grep` or `<Esc>` to abort.

![grep_in_files](https://github.com/brookhong/telescope-pathogen.nvim/assets/288207/05f54ddb-06ee-4951-8bef-d30cf178035e)

* Continuous search to help you continuously search in previous search result to generate a new result which should include or exclude another pattern, which works for both `live_grep` and `grep_string`.
    * `Ctrl-0` to initiate another search(invert grep) among the previous results to exclude another pattern.
    * `Ctrl-1` to initiate another search(grep) among the previous results to include another pattern.
    * `Ctrl-b` to go back to previous search.

[Showcase on Youtube](https://www.youtube.com/watch?v=cCeIuBG4vYM)

### file browser

A quick ui within telescope to pick up file or directory.

* `CR` pick up the file or directory.
* `Tab` pick up the file or directory.
* `,` edit current working directory.
* `C-o` navigate to parent directory.
* `C-e` trigger `live_grep` within picked directory.
* `C-f` trigger `find_files` within picked directory.
* `A-c` copy current selection to another file or create a new file.
* `A-d` delete current selection.
* `A-t` open terminal from current working directory.

![d](https://user-images.githubusercontent.com/288207/225836274-713eb4ee-1330-4dc6-9649-47701b993081.gif)

## 📦 Installation

Use [lazy.nvim](https://github.com/folke/lazy.nvim)

    {
        "nvim-telescope/telescope.nvim",
        dependencies = {
            { "telescope-pathogen.nvim" },
        },
        config = function()
            require("telescope").setup({
                extensions = {
                    ["pathogen"] = {
                        -- remove below if you want to enable it
                        use_last_search_for_live_grep = false
                    }
                },
            })
            require("telescope").load_extension("pathogen")
            vim.keymap.set('v', '<space>g', require("telescope").extensions["pathogen"].grep_string)
        end,
        keys = {
            { "<space>a", ":Telescope pathogen live_grep<CR>", silent = true },
            { "<C-p>", ":Telescope pathogen<CR>", silent = true },
            { "<C-f>", ":Telescope pathogen find_files<CR>", silent = true },
            { "<space>g", ":Telescope pathogen grep_string<CR>", silent = true },
        }
    }
