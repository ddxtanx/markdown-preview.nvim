-- tests/floor_guard_test.lua
-- Below Neovim 0.10 every documented command, each of its subcommands and
-- each command from before the rename is a refuser that answers each use
-- with the floor module's text and the module answers a config's
-- setup() without loading the plugin or kitehost (one ERROR notification
-- at load between them), unless the config opted out under either load
-- guard; on a supported version the commands are defined. The module's name
-- from before the rename hands back the same table, warning once a session
-- above the floor and adding nothing below it.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/floor_guard_test.lua"
-- kitehost.nvim is found by tests/helpers.lua ($KITEHOST_RTP,
-- ./kitehost-rtp, the checkout's sibling kitehost.nvim).
local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()
local plugin_file = H.root .. "/plugin/mdkite.lua"
-- The plugin's entry module and its name from before the rename, the load
-- guards a config sets to opt out, the commands from before the rename, the
-- prefixes the commands of both names share and the features its floor
-- module tests beside the version.
local MODULE = "mdkite"
local ALIAS = "markdown_preview"
local GUARDS = { "loaded_mdkite", "loaded_markdown_preview" }
local DEPRECATED = { "MarkdownPreview", "MarkdownPreviewRefresh", "MarkdownPreviewStop" }
local COMMAND_PREFIXES = { "MdKite", "MarkdownPreview" }
local FEATURES = { "uv", "fs.joinpath", "uri_encode" }

-- The documented commands, sorted, and each documented subcommand as a
-- command line: the README's tables, whose rows name a command in its own
-- backticks, the command table's with the subcommand in the next column
-- and the upgrading table's with the command it runs.
local documented, subcommands = {}, {}
for line in io.lines(H.root .. "/README.md") do
	local name = line:match("^| `:(%w+)`")
	if name and not vim.tbl_contains(documented, name) then
		table.insert(documented, name)
	end
	local sub = line:match("^| `:%w+`%s*|%s*`([%w-]+)`")
	if sub then
		table.insert(subcommands, name .. " " .. sub)
	end
end
-- Every command the plugin defines: the documented ones and, through the
-- 2.x releases, the ones from before the rename, refused below the floor
-- as the documented ones are. Those the README does not list are kept
-- apart: tests/floor_smoke.sh drives below the floor only what it lists.
local commands, unlisted = vim.deepcopy(documented), {}
for _, name in ipairs(DEPRECATED) do
	if not vim.tbl_contains(commands, name) then
		table.insert(commands, name)
		table.insert(unlisted, name)
	end
end
table.sort(documented)
table.sort(commands)
documented = table.concat(documented, " ")
commands = table.concat(commands, " ")

-- The plugin's commands Neovim has, by the prefixes, sorted: a set equal to
-- the one above is every command the plugin defines and no other.
local function defined()
	local names = {}
	for name in pairs(vim.api.nvim_get_commands({})) do
		for _, prefix in ipairs(COMMAND_PREFIXES) do
			if vim.startswith(name, prefix) then
				table.insert(names, name)
				break
			end
		end
	end
	table.sort(names)
	return table.concat(names, " ")
end

-- A loaded module of this plugin or of kitehost besides the entry module
-- and the floor module is code that needs 0.10.
local function loaded_below()
	local found = {}
	for name in pairs(package.loaded) do
		local plugin = name == MODULE or vim.startswith(name, MODULE .. ".")
		local ls = name == "kitehost" or vim.startswith(name, "kitehost.")
		if (plugin or ls) and name ~= MODULE and name ~= MODULE .. ".floor" then
			table.insert(found, name)
		end
	end
	table.sort(found)
	return table.concat(found, ", ")
end

-- The floor module's verdict, its chunk run against a vim that lacks field
-- (a dotted name; nil hides nothing), since a field removed from the running
-- vim can come back through its lazy loader (vim.uri_encode does, measured).
local function floor_ok_without(field)
	local chunk = assert(loadfile(H.root .. "/lua/" .. MODULE .. "/floor.lua"))
	local function proxy(real, prefix)
		return setmetatable({}, {
			__index = function(_, key)
				local name = prefix .. key
				if name == field then
					return nil
				end
				local value = real[key]
				if type(value) == "table" and field and vim.startswith(field, name .. ".") then
					return proxy(value, name .. ".")
				end
				return value
			end,
		})
	end
	setfenv(chunk, setmetatable({ vim = proxy(vim, "") }, { __index = _G }))
	return chunk().ok
end

-- What a pcall returned, or what it raised, as one value: an and/or idiom
-- would read a false verdict as a raise.
local function outcome(done, value)
	if done then
		return value
	end
	return "raised " .. tostring(value)
end

-- The guard's return comes before every require but the floor module's, in
-- the source, a pcall(require, ...) included, so a require moved above it
-- reds even when the module it loads happens to need nothing newer.
local function guard_precedes_requires()
	local src = table.concat(vim.fn.readfile(H.root .. "/lua/" .. MODULE .. "/init.lua"), "\n")
	src = src:gsub("%-%-[^\n]*", "")
	local guard = src:find("if not floor.ok then", 1, true)
	local ret = guard and src:find("return setmetatable", guard, true)
	local first
	for _, pattern in ipairs({
		"()require%s*%(?%s*[\"']([^\"']+)[\"']",
		"()pcall%s*%(%s*require%s*,%s*[\"']([^\"']+)[\"']",
	}) do
		for at, name in src:gmatch(pattern) do
			if name ~= MODULE .. ".floor" then
				first = math.min(first or at, at)
				break
			end
		end
	end
	return guard ~= nil and ret ~= nil and (first == nil or ret < first),
		("guard at %s, its return at %s, the first other require at %s"):format(guard, ret, first)
end

-- Every refusal is recorded, notify_once's own dedupe aside, so the plugin
-- file's and the module's are checked apart; a refuser's goes through
-- vim.notify, since each use answers.
local notices, refusals = {}, {}
local real_once, real_notify = vim.notify_once, vim.notify
vim.notify_once = function(msg, level)
	notices[#notices + 1] = { msg = msg, level = level }
end
vim.notify = function(msg, level)
	refusals[#refusals + 1] = { msg = msg, level = level }
end
local real_has = vim.fn.has
vim.fn.has = function(feature)
	if feature == "nvim-0.10" then
		return 0
	end
	return real_has(feature)
end
local function turn_loop()
	vim.wait(50, function()
		return false
	end)
end

-- The plugin file sourced under pcall: a raise is the answer of the row
-- that reads the source, where it ended the suite with no Results line.
local function source_plugin()
	local done, err = pcall(vim.cmd, "source " .. vim.fn.fnameescape(plugin_file))
	return not done and ("source raised " .. tostring(err)) or nil
end

H.section("Section 1: below the floor")
H.ok(documented ~= "", "the README's command table lists the commands: " .. documented)
H.ok(#subcommands > 0, "the README's command table lists the subcommands: " .. table.concat(subcommands, ", "))
H.eq(table.concat(unlisted, " "), "", "the README's upgrading table lists each command from before the rename")
-- A config that sets a load guard has opted out, and an old-Neovim host
-- that shares the config must not be told at every start; the guard from
-- before the rename still opts out.
local source_err
for _, guard in ipairs(GUARDS) do
	vim.g[guard] = 1
	package.loaded[MODULE] = nil
	source_err = source_plugin()
	-- lazy.nvim's config still calls setup(), which answers without a word too.
	local quiet_ok, quiet_err = pcall(function()
		require(MODULE).setup({})
	end)
	turn_loop()
	H.eq(
		source_err
			or ("%d notices, commands %q, setup %s"):format(
				#notices + #refusals,
				defined(),
				quiet_ok and "returned" or ("raised " .. tostring(quiet_err))
			),
		'0 notices, commands "", setup returned',
		"a config that set " .. guard .. " hears nothing below the floor, from the plugin file or the module"
	)
	-- The opted-out load's notices are read above; the next load counts its own.
	notices = {}
	refusals = {}
	vim.g[guard] = nil
end
package.loaded[MODULE] = nil
source_err = source_plugin()
local message = require(MODULE .. ".floor").message
H.ok(vim.startswith(message, "mdkite: "), "the floor text starts mdkite:, as every notice does: " .. message)
H.ok(message:find("0.10", 1, true) ~= nil, "the floor text names the floor")
-- lazy.nvim's cmd and keys specs run the command they were given, so each
-- documented one, and each from before the rename, exists below the floor
-- to say why.
H.eq(
	source_err or defined(),
	commands,
	"every documented command and every one from before the rename is defined below the floor, and no other"
)
-- lazy.nvim sources plugin files with :source, where an ERROR notification
-- on 0.9 raised a Vim(source) exception, so the refusal waits for the source
-- to return and shows once the loop turns.
H.eq(#notices, 0, "the plugin file's refusal waits until the :source returns")
vim.wait(1000, function()
	return #notices > 0
end)
H.eq(#notices, 1, "the plugin file refuses with one notification")
-- A vim.notify a load queues beside its notify_once would be counted by the
-- next case's rows, so each load's is read where it happens and cleared.
turn_loop()
H.eq(#refusals, 0, "the plugin file's load notifies through notify_once alone")
refusals = {}
-- A refusal that set the load guard would keep a later source on a
-- supported Neovim from defining the commands.
for _, guard in ipairs(GUARDS) do
	H.eq(vim.g[guard], nil, "a refused load leaves " .. guard .. " unset")
end
-- A cmd spec runs the command through vim.cmd inside lazy.nvim's handler,
-- where an ERROR notification on 0.9 raised a traceback, so a refuser's waits
-- too; every use answers, a second one and one naming a subcommand included.
local names = vim.split(commands, " ")
-- Under pcall, so a command that is missing reds its own rows below and not
-- the whole suite.
for _, name in ipairs(names) do
	pcall(vim.cmd, name)
end
for _, line in ipairs(subcommands) do
	pcall(vim.cmd, line)
end
H.eq(#refusals, 0, "a refuser's answer waits until the command returns")
pcall(vim.cmd, names[1])
turn_loop()
H.eq(
	#refusals,
	#names + #subcommands + 1,
	"every command, each documented subcommand included, answers each use below the floor"
)
local refused_right = #refusals > 0
for _, refusal in ipairs(refusals) do
	refused_right = refused_right and refusal.msg == message and refusal.level == vim.log.levels.ERROR
end
H.ok(refused_right, "every refuser answers with the floor text as an ERROR")
refusals = {}
-- lazy.nvim's config calls setup() whatever the plugin file did.
package.loaded[MODULE] = nil
local setup_ok, setup_err = pcall(function()
	require(MODULE).setup({})
end)
H.ok(setup_ok, "setup() raises nothing below the floor" .. (setup_ok and "" or (": " .. tostring(setup_err))))
H.eq(loaded_below(), "", "the module returns before any module but the floor module loads")
local structural, where = guard_precedes_requires()
H.ok(structural, "the module's floor guard returns before its first require but the floor module's: " .. where)
-- A lazy load on FileType runs the module inside 0.9's filetype nvim_cmd,
-- where an ERROR notification raised Vim(append), so this refusal waits too.
H.eq(#notices, 1, "the module's refusal waits until the require returns")
vim.wait(1000, function()
	return #notices > 1
end)
H.eq(#notices, 2, "the module refuses with one notification too")
turn_loop()
H.eq(#refusals, 0, "the module's load notifies through notify_once alone")
-- Any field a config calls answers an empty string, never a nil.
local other_ok, other = pcall(function()
	return require(MODULE).anything_else()
end)
H.eq(
	other_ok and tostring(other) or ("raised " .. tostring(other)),
	"",
	"an undocumented field on the stub answers the same"
)
-- notify_once shows a text once, so the floor module's text in both
-- refusals is one notification on screen, whichever of them runs first.
local all_floor_text, all_errors = #notices > 0, #notices > 0
for _, notice in ipairs(notices) do
	all_floor_text = all_floor_text and notice.msg == message
	all_errors = all_errors and notice.level == vim.log.levels.ERROR
end
H.ok(all_floor_text, "both refusals are the floor module's text, so the user sees one notification")
H.ok(all_errors, "every refusal is an ERROR")
-- The name from before the rename hands back the stub, and a config that
-- requires it first hears the floor text alone: its warning follows the
-- floor check.
notices = {}
package.loaded[MODULE] = nil
local alias_ok, alias = pcall(require, ALIAS)
turn_loop()
H.eq(
	alias_ok and (alias == package.loaded[MODULE] and "the module's table" or "another table")
		or ("raised " .. tostring(alias)),
	"the module's table",
	"require(" .. vim.inspect(ALIAS) .. ") hands back the module's stub below the floor"
)
H.eq(
	#notices == 1 and notices[1].msg or (#notices .. " notices"),
	message,
	"require(" .. vim.inspect(ALIAS) .. ") below the floor gives the floor text and no warning"
)
H.eq(#refusals, 0, "require(" .. vim.inspect(ALIAS) .. ") below the floor notifies through notify_once alone")
-- notify_once arrived in 0.7 and a Lua plugin file is sourced from 0.5 on,
-- so without it each guard shows the text through vim.notify, once.
vim.notify_once = nil
refusals = {}
for name in pairs(package.loaded) do
	if name == MODULE or vim.startswith(name, MODULE .. ".") then
		package.loaded[name] = nil
	end
end
source_err = source_plugin()
turn_loop()
H.eq(
	source_err or (#refusals == 1 and refusals[1].msg or #refusals),
	message,
	"without notify_once the plugin file shows the text once"
)
refusals = {}
local again_ok, again_err = pcall(function()
	require(MODULE).setup({})
end)
turn_loop()
H.eq(
	not again_ok and ("setup() raised " .. tostring(again_err)) or (#refusals == 1 and refusals[1].msg or #refusals),
	message,
	"without notify_once the module shows the text once"
)
-- A Neovim before 0.8 has no vim.fs, and one with a vim.uv = vim.loop
-- polyfill passed a vim.uv test into an index of it (measured on 0.7.2
-- and 0.6.1), so below the floor the predicate answers false without
-- raising where the first table of any feature it tests is missing.
for _, field in ipairs(FEATURES) do
	local first = field:match("^[^.]+")
	H.eq(
		outcome(pcall(floor_ok_without, first)),
		false,
		"below the floor the predicate answers without vim." .. first .. " and raises nothing"
	)
end

H.section("Section 2: at the floor")
vim.fn.has = real_has
vim.notify_once = real_once
vim.notify = real_notify
for _, guard in ipairs(GUARDS) do
	vim.g[guard] = nil
end
-- The refusers go, so every command counted below is the real plugin's.
for _, name in ipairs(names) do
	pcall(vim.api.nvim_del_user_command, name)
end
-- The stub and the floor module's verdict go with every other module of
-- this plugin, its name from before the rename and kitehost's, and so
-- does the sentinel require leaves for a module that raised while loading.
for name in pairs(package.loaded) do
	local plugin = name == MODULE or name == ALIAS or vim.startswith(name, MODULE .. ".")
	if plugin or name == "kitehost" or vim.startswith(name, "kitehost.") then
		package.loaded[name] = nil
	end
end
H.eq(outcome(pcall(floor_ok_without, nil)), true, "the floor admits this Neovim")
for _, field in ipairs(FEATURES) do
	H.eq(
		outcome(pcall(floor_ok_without, field)),
		false,
		"the floor refuses a Neovim without vim." .. field .. ", whatever its version"
	)
end
-- Either load guard opts out on a supported Neovim too.
for _, guard in ipairs(GUARDS) do
	vim.g[guard] = 1
	local skipped_err = source_plugin()
	H.eq(
		skipped_err or ("commands %q, module %s"):format(defined(), package.loaded[MODULE] and "loaded" or "unloaded"),
		'commands "", module unloaded',
		"a config that set " .. guard .. " gets no command and no module on a supported Neovim"
	)
	vim.g[guard] = nil
end
-- Under pcall, so a plugin that raises at the floor reds this row and not
-- the whole suite.
local sourced, source_err = pcall(vim.cmd, "source " .. vim.fn.fnameescape(plugin_file))
H.eq(
	sourced and "sourced" or ("raised " .. tostring(source_err)),
	"sourced",
	"the plugin file sources without raising on a supported Neovim"
)
-- By type: a left-over stub answers config with a function.
local module_ok, module = pcall(require, MODULE)
H.ok(
	module_ok and type(module.config) == "table" and type(package.loaded["kitehost.server"]) == "table",
	"the plugin's own modules and kitehost's load on a supported Neovim"
		.. (module_ok and "" or (": " .. tostring(module)))
)
H.eq(
	defined(),
	commands,
	"every command, the ones from before the rename included, is defined on a supported Neovim, and no other"
)
-- The name from before the rename hands back the module's own table, so a
-- config's setup() reaches the state the commands use, and warns once a
-- session, naming the plugin: without it vim.deprecate stays silent. The
-- repository is named beside the module, since lazy.nvim makes that require
-- itself for a spec that still names the old repository.
local warned = {}
vim.notify = function(msg, level)
	table.insert(warned, { msg = msg, level = level })
end
local first_ok, first = pcall(require, ALIAS)
package.loaded[ALIAS] = nil
local again_ok, again = pcall(require, ALIAS)
vim.notify = real_notify
H.eq(
	(first_ok and again_ok) and ((first == module and again == module) and "the module's table" or "another table")
		or ("raised " .. tostring(first_ok and again or first)),
	"the module's table",
	"require(" .. vim.inspect(ALIAS) .. ") hands back the module's own table on a supported Neovim"
)
H.eq(#warned, 1, "require(" .. vim.inspect(ALIAS) .. ") warns once a session, a second require included")
local warning = warned[1] or {}
H.eq(warning.level, vim.log.levels.WARN, "the warning is a WARN")
H.ok(
	(warning.msg or ""):find('use require("mdkite") from selimacerbas/mdkite.nvim instead', 1, true) ~= nil
		and (warning.msg or ""):find("removed in mdkite.nvim 3.0.0", 1, true) ~= nil,
	"the warning names the module, its repository and the plugin: " .. tostring(warning.msg)
)
H.finish()
