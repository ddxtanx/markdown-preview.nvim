-- tests/command_test.lua
-- :MdKite runs the subcommand its first argument names, and start when it
-- names none; completion offers the subcommands for that argument alone; an
-- unknown subcommand, or a second argument, is one error notice naming the
-- known ones. The commands from before the rename run their subcommand and
-- warn once a session each. Sections 5 and 6 drive toggle against a real
-- server: it starts a stopped preview and stops a running one, a preview
-- joined to another Neovim's included.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/command_test.lua"
-- live-server.nvim is found by tests/helpers.lua ($LIVE_SERVER_RTP,
-- ./live-server-rtp, the checkout's sibling live-server.nvim).

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
local ls_dir = H.rtp()
local eq, ok = H.eq, H.ok

vim.cmd("source " .. vim.fn.fnameescape(H.root .. "/plugin/mdkite.lua"))
local mp = require("mdkite")
local SUBCOMMANDS = { "start", "stop", "refresh", "toggle" }
local FORWARDED = { MarkdownPreview = "start", MarkdownPreviewRefresh = "refresh", MarkdownPreviewStop = "stop" }

-- Runs cmdline with each function a subcommand reaches recorded instead of
-- run; the names called, in order, and the notices made.
local function dispatched(cmdline)
	local called, notes = {}, {}
	local real, real_notify = {}, vim.notify
	for _, name in ipairs(SUBCOMMANDS) do
		real[name] = mp[name]
		mp[name] = function()
			table.insert(called, name)
		end
	end
	vim.notify = function(msg, level)
		table.insert(notes, { msg = msg, level = level })
	end
	local ran, err = pcall(vim.cmd, cmdline)
	vim.notify = real_notify
	for name, fn in pairs(real) do
		mp[name] = fn
	end
	if not ran then
		error(cmdline .. " raised: " .. tostring(err), 0)
	end
	return table.concat(called, " "), notes
end

H.case("Section 1: each subcommand runs its function", function()
	for _, sub in ipairs(SUBCOMMANDS) do
		local called, notes = dispatched("MdKite " .. sub)
		eq(called, sub, ":MdKite " .. sub .. " runs " .. sub)
		eq(#notes, 0, ":MdKite " .. sub .. " adds no notice of its own")
	end
	eq((dispatched("MdKite")), "start", "a bare :MdKite runs start")
end)

H.case("Section 2: an unknown subcommand is one error naming the known ones", function()
	for _, cmdline in ipairs({ "MdKite nope", "MdKite start extra" }) do
		local called, notes = dispatched(cmdline)
		eq(called, "", cmdline .. " runs nothing")
		eq(#notes, 1, cmdline .. " gives one notice")
		local note = notes[1] or {}
		eq(note.level, vim.log.levels.ERROR, cmdline .. " gives an error")
		ok(
			vim.startswith(note.msg or "", "mdkite: unknown subcommand ")
				and vim.endswith(note.msg or "", table.concat(SUBCOMMANDS, ", ")),
			cmdline .. " names the subcommands: " .. tostring(note.msg)
		)
	end
end)

H.case("Section 3: completion offers the subcommands for the first argument", function()
	local function offered(line)
		return table.concat(vim.fn.getcompletion(line, "cmdline"), " ")
	end
	eq(offered("MdKite "), table.concat(SUBCOMMANDS, " "), "the first argument offers every subcommand")
	eq(offered("MdKite st"), "start stop", "a typed prefix narrows them")
	eq(offered("silent MdKite t"), "toggle", "a modifier before the command counts for nothing")
	eq(offered("MdKite start "), "", "the second argument offers nothing")
end)

H.case("Section 4: each command from before the rename runs its subcommand, warned once", function()
	local names = vim.tbl_keys(FORWARDED)
	table.sort(names)
	for _, name in ipairs(names) do
		local sub = FORWARDED[name]
		local called, notes = dispatched(name)
		eq(called, sub, ":" .. name .. " runs " .. sub)
		eq(#notes, 1, ":" .. name .. " warns at its first use")
		local note = notes[1] or {}
		eq(note.level, vim.log.levels.WARN, ":" .. name .. " warns as a WARN")
		ok(
			(note.msg or ""):find(("use :MdKite %s instead"):format(sub), 1, true) ~= nil
				and (note.msg or ""):find("mdkite.nvim", 1, true) ~= nil,
			":" .. name .. " names :MdKite " .. sub .. " and the plugin: " .. tostring(note.msg)
		)
		called, notes = dispatched(name)
		eq(called, sub, ":" .. name .. " runs " .. sub .. " again")
		eq(#notes, 0, ":" .. name .. " warns once a session")
	end
end)

local tmpdir = H.tmpdir()
local md = vim.fs.joinpath(tmpdir, "doc.md")
H.write_file(md, "# toggled\n")
vim.cmd("edit " .. vim.fn.fnameescape(md))
vim.bo.filetype = "markdown"

-- A port free a moment ago, so no row meets the developer's own preview on
-- the takeover default 8421.
local function free_port()
	local probe = vim.uv.new_tcp()
	probe:bind("127.0.0.1", 0)
	local port = probe:getsockname().port
	probe:close()
	return port
end

H.case("Section 5: toggle starts a stopped preview and stops a running one", function()
	mp.setup({ open_browser = false, instance_mode = "multi", port = 0 })
	H.defer(mp.stop)
	vim.cmd("MdKite toggle")
	local inst = mp._server_instance
	ok(inst ~= nil, "toggle starts a stopped preview")
	local url = ("http://127.0.0.1:%d/"):format(inst and inst.port or 0)
	eq(H.http_get(url).status, 200, "the started preview answers")
	vim.cmd("MdKite toggle")
	eq(mp._server_instance, nil, "toggle stops a running preview")
	-- The close takes a turn of the loop before the port refuses (curl 7).
	vim.wait(200, function()
		return false
	end)
	eq(H.http_get(url).curl_exit, 7, "the stopped preview's port refuses connections")
	vim.cmd("MdKite toggle")
	ok(mp._server_instance ~= nil, "toggle starts it again")
end)

-- A second Neovim serving path as the takeover primary on port, in this
-- process's cache, until the enclosing case ends; it exits by itself after
-- 30 s if the kill is missed.
local function child_primary(path, port)
	local script = vim.fs.joinpath(H.tmpdir(), "primary.lua")
	H.write_file(
		script,
		([=[
vim.opt.runtimepath:prepend(%q)
vim.opt.runtimepath:prepend(%q)
local mp = require("mdkite")
mp.setup({ open_browser = false, instance_mode = "takeover", port = %d })
vim.cmd("edit " .. vim.fn.fnameescape(%q))
vim.bo.filetype = "markdown"
mp.start()
local inst = mp._server_instance
io.stdout:write(vim.json.encode({ port = inst and inst.port or 0 }) .. "\n")
io.stdout:flush()
vim.wait(30000, function() return false end)
]=]):format(ls_dir, H.root, port, path)
	)
	local said = {}
	local proc = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", script }, {
		stdout = function(_, data)
			if data then
				table.insert(said, data)
			end
		end,
	})
	H.defer(function()
		proc:kill(9)
		proc:wait(5000)
	end)
	if not H.wait_for(function()
		return table.concat(said):find("\n", 1, true) ~= nil
	end, 10000) then
		error("child_primary: the child said nothing in 10 s", 0)
	end
	local line = table.concat(said):match("({.-})")
	local decoded, got = pcall(vim.json.decode, line or "")
	if not decoded or type(got) ~= "table" or got.port ~= port then
		error("child_primary: the child did not serve port " .. port .. ": " .. table.concat(said), 0)
	end
end

H.case("Section 6: toggle stops a preview joined to another Neovim's", function()
	local port = free_port()
	child_primary(md, port)
	mp.setup({ open_browser = false, instance_mode = "takeover", port = port })
	H.defer(function()
		mp.stop()
		mp.setup({ instance_mode = "multi", port = 0 })
	end)
	vim.cmd("MdKite toggle")
	eq(mp._is_primary, false, "toggle joins the other Neovim's preview")
	vim.cmd("MdKite toggle")
	eq(mp._is_primary, nil, "toggle leaves the joined preview")
	eq(mp._server_instance, nil, "and starts no server of its own")
	eq(H.http_get(("http://127.0.0.1:%d/"):format(port)).status, 200, "the other Neovim's preview still answers")
end)

H.finish()
