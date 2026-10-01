-- plugin/mdkite.lua
-- A config that sets loaded_mdkite, or loaded_markdown_preview from before
-- the rename, has opted out, on any Neovim, so both are read before the
-- floor and nothing is said.
if vim.g.loaded_mdkite or vim.g.loaded_markdown_preview then
	return
end

-- The subcommands, in the order completion offers them, and each command
-- from before the rename with the subcommand it forwards to through the
-- 2.x releases.
local SUBCOMMANDS = { "start", "stop", "refresh", "toggle" }
local FORWARDED = { MarkdownPreview = "start", MarkdownPreviewRefresh = "refresh", MarkdownPreviewStop = "stop" }

-- mdkite needs Neovim 0.10: vim.fs.joinpath, vim.uri_encode and vim.uv.
-- Below the floor every command, the old names included, is still defined,
-- as a refuser, so a lazy.nvim cmd or keys spec finds its command and each
-- use says why, and one notification says it at load; the load guard stays
-- unset, since the plugin has not loaded. Both wait for the loop: lazy.nvim
-- sources this file with :source and runs a cmd spec's command through
-- vim.cmd, where an ERROR notification on 0.9 raised Vim(source) or a
-- traceback through lazy's handler (measured).
local floor = require("mdkite.floor")
if not floor.ok then
	local function refuse()
		vim.schedule(function()
			vim.notify(floor.message, vim.log.levels.ERROR)
		end)
	end
	-- Lua user commands and notify_once arrived in 0.7, and this file is
	-- sourced from 0.5 on, where the notification at load is all there is.
	-- :MdKite takes its arguments, so a subcommand meets the refusal and not
	-- an E488.
	if vim.api.nvim_create_user_command then
		local desc = "mdkite: requires Neovim 0.10"
		vim.api.nvim_create_user_command("MdKite", refuse, { nargs = "*", desc = desc })
		for name in pairs(FORWARDED) do
			vim.api.nvim_create_user_command(name, refuse, { desc = desc })
		end
	end
	vim.schedule(function()
		local notify = vim.notify_once or vim.notify
		notify(floor.message, vim.log.levels.ERROR)
	end)
	return
end
vim.g.loaded_mdkite = true

-- Only the first argument names a subcommand. The line is parsed as Neovim
-- reads it, so a modifier or an abbreviated name before it counts for
-- nothing; a line it cannot parse offers them all.
local function complete(lead, line, pos)
	local parsed, cmd = pcall(vim.api.nvim_parse_cmd, line:sub(1, pos), {})
	local before = parsed and #cmd.args - (lead == "" and 0 or 1) or 0
	if before > 0 then
		return {}
	end
	return vim.tbl_filter(function(name)
		return vim.startswith(name, lead)
	end, SUBCOMMANDS)
end

-- A bare :MdKite starts the preview.
vim.api.nvim_create_user_command("MdKite", function(opts)
	local sub = opts.fargs[1] or "start"
	if #opts.fargs > 1 or not vim.tbl_contains(SUBCOMMANDS, sub) then
		vim.notify(
			("mdkite: unknown subcommand %q; the subcommands are %s"):format(opts.args, table.concat(SUBCOMMANDS, ", ")),
			vim.log.levels.ERROR
		)
		return
	end
	require("mdkite")[sub]()
end, { nargs = "*", complete = complete, desc = "mdkite: start, stop, refresh or toggle the preview" })

for name, sub in pairs(FORWARDED) do
	vim.api.nvim_create_user_command(name, function()
		local mdkite = require("mdkite")
		mdkite._deprecated(":" .. name, ":MdKite " .. sub)
		mdkite[sub]()
	end, { desc = "mdkite: the name before :MdKite " .. sub })
end
