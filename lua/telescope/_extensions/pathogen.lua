local has_telescope, telescope = pcall(require, "telescope")

if not has_telescope then
  error "This plugin requires telescope.nvim (https://github.com/nvim-telescope/telescope.nvim)"
end

local pathogen = require("pathogen")

return telescope.register_extension {
  setup = function(ext_config, config)
    for key,value in pairs(ext_config) do
        if pathogen.config[key] ~= nil then
            pathogen.config[key] = value
        end
    end
  end,
  exports = {
    pathogen = pathogen.browse_file,
    grep_string = pathogen.grep_string,
    find_files = pathogen.find_files,
    live_grep = pathogen.live_grep,
    grep_in_files = pathogen.grep_in_files,
    quick_buffer = pathogen.quick_buffer,
    find_project_root = pathogen.find_project_root,
    edit_loclist = pathogen.edit_loclist,
    edit_qflist = pathogen.edit_qflist,
  },
}
