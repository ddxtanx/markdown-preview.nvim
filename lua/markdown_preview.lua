-- lua/markdown_preview.lua
-- The module's name before the rename, kept through the 2.x releases. It
-- hands back the module's own table, so a config's setup() and the commands
-- share one state. The warning follows the floor check, so below the floor
-- the module's floor notice is all a config hears.
local mdkite = require("mdkite")
if require("mdkite.floor").ok then
	-- lazy.nvim itself calls this setup() for a spec naming the old repository, so the repository is named too.
	mdkite._deprecated('require("markdown_preview")', 'require("mdkite") from selimacerbas/mdkite.nvim')
end
return mdkite
