local has_telescope, telescope = pcall(require, "telescope")

if not has_telescope then
  error "This plugin requires telescope.nvim (https://github.com/nvim-telescope/telescope.nvim)"
end

local pathogen = require("pathogen")

return telescope.register_extension {
  setup = function(ext_config, config)
    -- access extension config and user config
    if ext_config.use_last_search_for_live_grep ~= nil then
        pathogen.use_last_search_for_live_grep = ext_config.use_last_search_for_live_grep
        pathogen.prompt_prefix_length = ext_config.prompt_prefix_length
    end
  end,
  exports = {
    pathogen = pathogen.browse_file,
    grep_string = pathogen.grep_string,
    find_files = pathogen.find_files,
    live_grep = pathogen.live_grep,
    grep_in_files = pathogen.grep_in_files,
    grep_in_result = pathogen.grep_in_result,
    invert_grep_in_result = pathogen.invert_grep_in_result,
    find_project_root = pathogen.find_project_root,
    edit_in_popup = pathogen.edit_in_popup,
    edit_loclist = pathogen.edit_loclist,
    edit_qflist = pathogen.edit_qflist,
  },
}
