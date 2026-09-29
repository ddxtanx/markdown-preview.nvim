-- tests/start_failure_test.lua
-- A start that fails leaves nothing behind: no autocmd refreshing a
-- preview that does not exist, no token, workspace pointer or takeover
-- role kept, no on_start; the notification names the port, and the next
-- start begins clean. Section 1 stubs live-server's start to raise and
-- Section 1b the lock's write, so they hold on every live-server the
-- plugin runs on, the pinned floor included. A retarget live-server
-- refuses leaves the served bytes as they were, and a retarget, a reload
-- and a scroll push it refuses are each told through the plugin's notice.
--
-- Run: nvim --headless -u NONE -l tests/start_failure_test.lua

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
local ls_dir = H.rtp()

local ls_server = require("live_server.server")
local eq, ok = H.eq, H.ok

local tmpdir = H.tmpdir()
local md = vim.fs.joinpath(tmpdir, "doc.md")
H.write_file(md, "# doc\n")
vim.cmd("edit " .. vim.fn.fnameescape(md))
vim.bo.filetype = "markdown"

local mp = require("markdown_preview")
local calls = { start = 0, stop = 0 }
mp.setup({
	open_browser = false,
	instance_mode = "multi",
	port = 18421,
	hooks = {
		on_start = function()
			calls.start = calls.start + 1
		end,
		on_stop = function()
			calls.stop = calls.stop + 1
		end,
	},
})

-- The plugin's autocmds; nvim_get_autocmds raises for a group that does
-- not exist, which counts as none.
local function armed()
	local got, list = pcall(vim.api.nvim_get_autocmds, { group = "MarkdownPreviewAuto" })
	return got and #list or 0
end

-- The plugin's autocmds on one buffer; no group counts as none.
local function armed_on(bufnr)
	local n = 0
	local got, list = pcall(vim.api.nvim_get_autocmds, { group = "MarkdownPreviewAuto" })
	for _, au in ipairs(got and list or {}) do
		if au.buffer == bufnr then
			n = n + 1
		end
	end
	return n
end

-- mp.start() with live-server's start raising msg; the notifications made.
local function start_raising(msg)
	local notes = {}
	local real_start, real_notify = ls_server.start, vim.notify
	ls_server.start = function()
		error(msg, 0)
	end
	vim.notify = function(text, level)
		table.insert(notes, { msg = text, level = level })
	end
	local ran, err = pcall(mp.start)
	ls_server.start, vim.notify = real_start, real_notify
	if not ran then
		error(err, 0)
	end
	return notes
end

-- Every notification until the enclosing case ends.
local function capture_notes()
	local notes = {}
	local real_notify = vim.notify
	vim.notify = function(text, level)
		table.insert(notes, { msg = text, level = level })
	end
	H.defer(function()
		vim.notify = real_notify
	end)
	return notes
end

-- Replaces ls_server[name] until the enclosing case ends.
local function stub(name, fn)
	local real = ls_server[name]
	ls_server[name] = fn
	H.defer(function()
		ls_server[name] = real
	end)
end

H.section("Section 1: a start that raises leaves no state behind")
local failed_notes = start_raising("Failed to bind 127.0.0.1:18421: EADDRINUSE: address already in use")
eq(#failed_notes, 1, "one notice for the failed start")
eq(failed_notes[1] and failed_notes[1].level, vim.log.levels.ERROR, "the notice is an error")
ok(
	failed_notes[1] ~= nil and failed_notes[1].msg:find("port 18421 is in use", 1, true) ~= nil,
	"the notice names the taken port: " .. tostring(failed_notes[1] and failed_notes[1].msg)
)
ok(
	failed_notes[1] ~= nil and failed_notes[1].msg:find('instance_mode = "multi"', 1, true) ~= nil,
	"and the setting that avoids it"
)
eq(armed(), 0, "no autocmd is armed")
eq(mp._token, nil, "the token is cleared")
eq(mp._workspace_dir, nil, "the workspace is cleared")
eq(mp._server_instance, nil, "no server instance is kept")
eq(calls.start, 0, "on_start is not called")
eq(calls.stop, 0, "on_stop is not called")

H.section("Section 1b: a lock that cannot be written leaves no state behind")
-- The takeover lock is written once the server listens; a lock that
-- cannot be made private stops the server again and fails the start.
local probe = vim.uv.new_tcp()
probe:bind("127.0.0.1", 0)
local free = probe:getsockname().port
probe:close()
mp.setup({ instance_mode = "takeover", port = free })
local lock = require("markdown_preview.lock")
local real_write, real_notify_1b = lock.write, vim.notify
lock.write = function()
	error("stubbed: the lockfile cannot be made private", 0)
end
vim.notify = function() end
mp.start()
lock.write, vim.notify = real_write, real_notify_1b
eq(armed(), 0, "no autocmd is armed after a lock failure")
eq(mp._token, nil, "the token is cleared")
eq(mp._workspace_dir, nil, "the workspace is cleared")
eq(mp._server_instance, nil, "no server instance is kept")
eq(calls.start, 0, "on_start is not called")
mp.setup({ instance_mode = "multi", port = 18421 })

-- A port no listener holds, for a start that must succeed.
local function free_port()
	local tcp = vim.uv.new_tcp()
	tcp:bind("127.0.0.1", 0)
	local port = tcp:getsockname().port
	tcp:close()
	return port
end

H.case("Section 1c: the start after a failed one arms, serves and opens the browser", function()
	local util = require("markdown_preview.util")
	local opened, real_open = 0, util.open_in_browser
	util.open_in_browser = function()
		opened = opened + 1
	end
	H.defer(function()
		util.open_in_browser = real_open
	end)
	mp.setup({ open_browser = true, port = free_port() })
	H.defer(function()
		mp.setup({ open_browser = false, port = 18421 })
	end)
	mp.start()
	H.defer(mp.stop)
	ok(armed() > 0, "the start arms its autocmds")
	eq(calls.start, 1, "on_start is called once")
	ok(
		H.wait_for(function()
			return opened == 1
		end, 2000),
		"the browser is opened once"
	)
	local port = mp._server_instance and mp._server_instance.port
	local r = H.http_get(("http://127.0.0.1:%d/content.md?t=%s"):format(port or 0, mp._token or ""))
	eq(r.status, 200, "the content is served with the new token")
end)
calls.start, calls.stop = 0, 0

H.case("Section 1c2: any other start failure keeps the generic notice", function()
	local notes = start_raising("Failed to bind 127.0.0.1:18421: EACCES: permission denied")
	eq(#notes, 1, "one notice for the failed start")
	eq(
		notes[1] and notes[1].msg,
		"Markdown Preview: failed to start server (port 18421): Failed to bind 127.0.0.1:18421: EACCES: permission denied",
		"the notice names the port and carries the reason"
	)
end)

-- A port another program listens on, for the start to meet the real
-- refusal; port nil or 0 lets the OS choose. A fixed port some other
-- listener already holds is taken too, so that listener is used as found.
local function held_port(addr, port)
	local tcp, tcp_err = vim.uv.new_tcp()
	if not tcp then
		error("held_port: " .. tostring(tcp_err), 0)
	end
	H.defer(function()
		tcp:close()
	end)
	local function taken(err)
		return port and port ~= 0 and tostring(err):find("EADDRINUSE: address already in use", 1, true) ~= nil
	end
	local bound, bind_err = tcp:bind(addr, port or 0)
	if not bound then
		if taken(bind_err) then
			return port
		end
		error("held_port: " .. tostring(bind_err), 0)
	end
	-- libuv may report a bind's EADDRINUSE only at the listen.
	local listening, listen_err = tcp:listen(8, function() end)
	if not listening then
		if taken(listen_err) then
			return port
		end
		error("held_port: " .. tostring(listen_err), 0)
	end
	local name, name_err = tcp:getsockname()
	if not name then
		error("held_port: " .. tostring(name_err), 0)
	end
	return name.port
end

-- A second Neovim listening on addr:port until the enclosing case ends;
-- it exits by itself after 30 s if the kill is missed.
local function child_holding(addr, port)
	local script = vim.fs.joinpath(H.tmpdir(), "hold.lua")
	H.write_file(
		script,
		([[
local tcp = vim.uv.new_tcp()
local bound, err = tcp:bind(%q, %d)
if bound then
	bound, err = tcp:listen(8, function() end)
end
io.stdout:write(bound and "listening\n" or ("refused " .. tostring(err) .. "\n"))
io.stdout:flush()
vim.wait(30000, function() return false end)
]]):format(addr, port)
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
		return #said > 0
	end, 10000) then
		error("child_holding: the child said nothing in 10 s", 0)
	end
	return table.concat(said)
end

H.case("Section 1c4: an OS-assigned port refused keeps the generic notice", function()
	mp.setup({ port = 0 })
	H.defer(function()
		mp.setup({ port = 18421 })
	end)
	local reason = "Failed to bind 127.0.0.1:53211: another socket holds a wildcard on port 53211,"
		.. " which this address would shadow (EADDRINUSE: address already in use)"
	local notes = start_raising(reason)
	eq(#notes, 1, "one notice for the failed start")
	eq(
		notes[1] and notes[1].msg,
		"Markdown Preview: failed to start server (port 0): " .. reason,
		"the notice carries the reason, which names the port the OS chose"
	)
end)

for _, holder in ipairs({ "this process", "another process" }) do
	H.case("Section 1c5: the default takeover port, held by " .. holder .. ", is named with its fix", function()
		if holder == "another process" then
			local said = child_holding("127.0.0.1", 8421)
			ok(
				said:find("listening", 1, true) or said:find("EADDRINUSE: address already in use", 1, true),
				"the child holds the port or finds it held: " .. said
			)
		end
		local port = held_port("127.0.0.1", 8421)
		mp.setup({ instance_mode = "takeover", port = 0 })
		H.defer(function()
			mp.setup({ instance_mode = "multi", port = 18421 })
		end)
		local notes = capture_notes()
		mp.start()
		eq(#notes, 1, "one notice for the failed start")
		eq(
			notes[1] and notes[1].msg,
			("Markdown Preview: port %d is in use by another program. Set port to a free one in setup(), "):format(port)
				.. 'or port = 0 with instance_mode = "multi" for an OS-assigned port.',
			"the notice names the port the start asked for"
		)
		eq(mp._server_instance, nil, "no server instance is kept")
	end)
end

H.case("Section 1c6: a host spelled like the error name keeps the generic notice", function()
	mp.setup({ host = "EADDRINUSE" })
	H.defer(function()
		mp.setup({ host = "127.0.0.1" })
	end)
	local notes = capture_notes()
	mp.start()
	eq(#notes, 1, "one notice for the failed start")
	ok(
		notes[1] ~= nil
			and vim.startswith(
				notes[1].msg,
				"Markdown Preview: failed to start server (port 18421): Failed to bind EADDRINUSE:"
			),
		"the notice is the generic one: " .. tostring(notes[1] and notes[1].msg)
	)
	eq(mp._server_instance, nil, "no server instance is kept")
end)

for _, shape in ipairs({
	{ held = "127.0.0.1", host = "127.0.0.1", what = "the same address" },
	{ held = "0.0.0.0", host = "127.0.0.1", what = "a wildcard" },
	{ held = "127.0.0.1", host = "0.0.0.0", what = "the loopback address a wildcard start names" },
}) do
	H.case("Section 1c3: a port held on " .. shape.what .. " is named with its fix", function()
		local port = held_port(shape.held)
		mp.setup({ host = shape.host, port = port })
		H.defer(function()
			mp.setup({ host = "127.0.0.1", port = 18421 })
		end)
		local notes = capture_notes()
		mp.start()
		eq(#notes, 1, "one notice for the failed start")
		eq(notes[1] and notes[1].level, vim.log.levels.ERROR, "the notice is an error")
		eq(
			notes[1] and notes[1].msg,
			("Markdown Preview: port %d is in use by another program. Set port to a free one in setup(), "):format(port)
				.. 'or port = 0 with instance_mode = "multi" for an OS-assigned port.',
			"the notice names the port and the settings that avoid it"
		)
		eq(mp._server_instance, nil, "no server instance is kept")
	end)
end

H.case("Section 1d: a failed start drops a takeover secondary's role", function()
	local lock = require("markdown_preview.lock")
	local real_read, real_alive = lock.read, lock.is_server_alive
	H.defer(function()
		lock.read, lock.is_server_alive = real_read, real_alive
	end)
	lock.read = function()
		return { port = 18422, token = "peer" }
	end
	lock.is_server_alive = function()
		return true
	end
	mp.setup({ instance_mode = "takeover", port = free_port() })
	H.defer(function()
		mp.setup({ instance_mode = "multi", port = 18421 })
	end)
	mp.start()
	ok(armed() > 0 and mp._takeover_port == 18422, "the start joins as a secondary")
	-- The primary is gone: no lock, and this start's own server fails.
	lock.read = function()
		return nil
	end
	start_raising("cannot listen: EADDRINUSE: address already in use")
	eq(armed(), 0, "no autocmd is left from the secondary")
	eq(mp._takeover_port, nil, "the secondary's port is dropped")
	eq(mp._is_primary, nil, "no role is kept")
	eq(mp._token, nil, "the peer's token is dropped")
end)
calls.start, calls.stop = 0, 0

H.section("Section 2: a start that succeeds arms the autocmds, a retarget keeps them")
mp.setup({ port = 0 })
mp.start()
ok(armed() > 0, "a started preview arms its autocmds")
local first_buf = vim.api.nvim_get_current_buf()
local second = vim.fs.joinpath(tmpdir, "second.md")
H.write_file(second, "# second\n")
vim.cmd("edit " .. vim.fn.fnameescape(second))
vim.bo.filetype = "markdown"
local second_buf = vim.api.nvim_get_current_buf()
mp.start()
local second_ws = mp._workspace_dir
ok(armed_on(second_buf) > 0, "a retarget arms them on the new buffer")
local second_text = vim.uv.fs_stat(vim.fs.joinpath(second_ws, "content.md"))
	and vim.fn.readblob(vim.fs.joinpath(second_ws, "content.md"))
ok(second_text and second_text:find("# second", 1, true), "an accepted retarget writes the new buffer's text")
ok(vim.uv.fs_stat(vim.fs.joinpath(second_ws, "index.html")), "an accepted retarget writes the index")
mp.stop()
calls.start, calls.stop = 0, 0

H.case("Section 3: a retarget live-server refuses keeps the preview where it was", function()
	vim.cmd("buffer " .. first_buf)
	mp.start()
	H.defer(mp.stop)
	local before = mp._workspace_dir
	local started = calls.start
	vim.cmd("buffer " .. second_buf)
	local notes = capture_notes()
	stub("update_target", function()
		error("update_target: root /gone does not resolve (ENOENT)", 2)
	end)
	mp.start()
	eq(#notes, 1, "one notice for a retarget that raised")
	eq(
		notes[1] and notes[1].msg,
		"Markdown Preview: could not retarget: update_target: root /gone does not resolve (ENOENT)",
		"the notice carries the raise's message"
	)
	eq(notes[1] and notes[1].level, vim.log.levels.ERROR, "the notice is an error")
	eq(mp._workspace_dir, before, "the workspace is the one served before")
	eq(armed_on(second_buf), 0, "no autocmd is armed on the buffer not shown")
	ok(armed_on(first_buf) > 0, "the shown buffer keeps its autocmds")
	eq(calls.start, started, "on_start is not called for a retarget that raised")
end)

H.case("Section 3b: a retarget that cannot watch says live reload is off", function()
	vim.cmd("buffer " .. first_buf)
	mp.start()
	H.defer(mp.stop)
	vim.cmd("buffer " .. second_buf)
	local notes = capture_notes()
	stub("update_target", function()
		return false
	end)
	mp.start()
	eq(#notes, 1, "one notice for a retarget that could not watch")
	eq(
		notes[1] and notes[1].msg,
		"Markdown Preview: the server reports live reload off; edits may not refresh the preview",
		"the notice says live reload is off and names no cause"
	)
	eq(notes[1] and notes[1].level, vim.log.levels.WARN, "the notice is a warning")
	eq(mp._workspace_dir, second_ws, "the workspace is the retargeted buffer's")
	ok(armed_on(second_buf) > 0, "the retargeted buffer is armed")
end)

H.case("Section 3c: a retarget whose reload live-server refuses says so", function()
	vim.cmd("buffer " .. first_buf)
	mp.start()
	H.defer(mp.stop)
	vim.cmd("buffer " .. second_buf)
	local notes = capture_notes()
	stub("reload", function()
		error("reload: the path is not a string (nil)", 2)
	end)
	mp.start()
	eq(#notes, 1, "one notice for a reload that raised on a retarget")
	eq(
		notes[1] and notes[1].msg,
		"Markdown Preview: could not reload the preview: reload: the path is not a string (nil)",
		"the notice carries the raise's message"
	)
	ok(armed_on(second_buf) > 0, "the retarget still arms the buffer")
end)

H.case("Section 3d: a takeover retarget live-server refuses leaves the served bytes", function()
	local other_dir = vim.fs.joinpath(tmpdir, "other")
	vim.fn.mkdir(other_dir, "p")
	local third = vim.fs.joinpath(other_dir, "third.md")
	H.write_file(third, "# third\n")
	mp.setup({ instance_mode = "takeover", port = free_port() })
	H.defer(function()
		mp.setup({ instance_mode = "multi", port = 18421 })
	end)
	vim.cmd("buffer " .. first_buf)
	mp.start()
	H.defer(mp.stop)
	local ws = mp._workspace_dir
	local content_file = vim.fs.joinpath(ws, "content.md")
	local root_file = vim.fs.joinpath(ws, "asset_root")
	local before = vim.fn.readblob(content_file)
	local first_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(first_buf))
	eq(vim.fn.readblob(root_file), first_dir, "the sidecar names the first buffer's directory")
	vim.cmd("edit " .. vim.fn.fnameescape(third))
	vim.bo.filetype = "markdown"
	local third_buf = vim.api.nvim_get_current_buf()
	local notes = capture_notes()
	stub("update_target", function()
		error("update_target: root is gone", 2)
	end)
	mp.start()
	eq(#notes, 1, "one notice for the refused retarget")
	eq(notes[1] and notes[1].level, vim.log.levels.ERROR, "the notice is an error")
	eq(vim.fn.readblob(content_file), before, "the served content is the first buffer's")
	eq(vim.fn.readblob(root_file), first_dir, "the sidecar still names the first buffer's directory")
	ok(armed_on(first_buf) > 0, "the first buffer keeps its autocmds")
	eq(armed_on(third_buf), 0, "the refused buffer is not armed")
end)

H.case("Section 4: a reload and a scroll push live-server refuses are told once each", function()
	vim.cmd("buffer " .. first_buf)
	mp.start()
	H.defer(mp.stop)
	local notes = capture_notes()
	stub("reload", function()
		error("reload: the path is not a string (nil)", 2)
	end)
	stub("send_event", function()
		error("send_event: the payload is not a string (nil)", 2)
	end)
	for i = 1, 2 do
		vim.api.nvim_buf_set_lines(first_buf, 0, -1, false, { "# doc " .. i, "", "a", "b", "c" })
		mp.refresh()
	end
	for _, line in ipairs({ 2, 4 }) do
		vim.api.nvim_win_set_cursor(0, { line, 0 })
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = first_buf })
	end
	local reloads, scrolls = {}, {}
	for _, n in ipairs(notes) do
		if n.msg:find("reload: the path is not a string", 1, true) then
			table.insert(reloads, n)
		elseif n.msg:find("send_event: the payload is not a string", 1, true) then
			table.insert(scrolls, n)
		end
	end
	eq(#notes, 2, "two notices in all")
	eq(#reloads, 1, "a reload that raised is told once")
	eq(#scrolls, 1, "a scroll push that raised is told once")
	eq(reloads[1] and reloads[1].level, vim.log.levels.WARN, "the reload notice is a warning")
	eq(scrolls[1] and scrolls[1].level, vim.log.levels.WARN, "the scroll notice is a warning")
end)

H.case("Section 5: a restart syncs the line the cursor already holds", function()
	vim.cmd("buffer " .. first_buf)
	vim.api.nvim_buf_set_lines(first_buf, 0, -1, false, { "# doc", "", "a", "b", "c" })
	mp.start()
	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	vim.api.nvim_exec_autocmds("CursorMoved", { buffer = first_buf })
	mp.stop()
	mp.start()
	H.defer(mp.stop)
	local scrolls = 0
	local real_send = ls_server.send_event
	stub("send_event", function(inst, event, data)
		if event == "scroll" then
			scrolls = scrolls + 1
		end
		return real_send(inst, event, data)
	end)
	vim.api.nvim_exec_autocmds("CursorMoved", { buffer = first_buf })
	eq(scrolls, 1, "the first cursor event after a restart sends the scroll")
end)

-- A second Neovim serving path as the takeover primary on port, in this
-- process's cache, until the enclosing case ends; it exits by itself after
-- 30 s if the kill is missed. Returns what it reports: its token and port.
local function child_primary(path, port)
	local script = vim.fs.joinpath(H.tmpdir(), "primary.lua")
	H.write_file(
		script,
		([=[
vim.opt.runtimepath:prepend(%q)
vim.opt.runtimepath:prepend(%q)
local mp = require("markdown_preview")
mp.setup({ open_browser = false, instance_mode = "takeover", port = %d })
vim.cmd("edit " .. vim.fn.fnameescape(%q))
vim.bo.filetype = "markdown"
mp.start()
local inst = mp._server_instance
io.stdout:write(vim.json.encode({ token = mp._token or "", port = inst and inst.port or 0 }) .. "\n")
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
	return got
end

H.case("Section 6: a refused start leaves a running preview's files and lock alone", function()
	local lock = require("markdown_preview.lock")
	local lock_file = vim.fs.joinpath(vim.fn.stdpath("cache"), "markdown-preview", "server.lock")
	H.defer(lock.remove)
	-- The lock's bytes, or a word that says it is gone.
	local function lock_bytes()
		return vim.uv.fs_stat(lock_file) and vim.fn.readblob(lock_file) or "(no lock)"
	end
	local a_md = vim.fs.joinpath(tmpdir, "a.md")
	H.write_file(a_md, "# served by the primary\n")
	local port = free_port()
	local primary = child_primary(a_md, port)
	local held = lock_bytes()
	ok(held:find(primary.token, 1, true) ~= nil, "the primary's lock holds its token")
	-- A probe that timed out, as a starved machine's did: this instance
	-- reads the live primary as gone and starts a server of its own.
	local real_alive = lock.is_server_alive
	lock.is_server_alive = function()
		return false
	end
	H.defer(function()
		lock.is_server_alive = real_alive
	end)
	local b_md = vim.fs.joinpath(tmpdir, "b.md")
	H.write_file(b_md, "# this instance's buffer\n")
	vim.cmd("edit " .. vim.fn.fnameescape(b_md))
	vim.bo.filetype = "markdown"
	mp.setup({ instance_mode = "takeover", port = port })
	H.defer(function()
		mp.setup({ instance_mode = "multi", port = 18421 })
	end)
	local notes = capture_notes()
	mp.start()
	eq(#notes, 1, "one notice for the refused start")
	eq(mp._server_instance, nil, "no server instance is kept")
	local content = H.http_get(("http://127.0.0.1:%d/content.md?t=%s"):format(port, primary.token))
	ok(
		content.status == 200 and content.body:find("# served by the primary", 1, true) ~= nil,
		("the primary still serves its own buffer: %d %s"):format(content.status, content.body)
	)
	local index = H.http_get(("http://127.0.0.1:%d/"):format(port))
	eq(
		index.body:match('data%-live%-token="([^"]*)"'),
		primary.token,
		"the primary's index still bakes the primary's token"
	)
	eq(lock_bytes(), held, "the refused start leaves the primary's lock")
	mp.stop()
	eq(lock_bytes(), held, "a stop after the refused start leaves the primary's lock")
end)
calls.start, calls.stop = 0, 0

-- vim.uv.fs_open refuses a write of a file whose name ends in suffix until
-- the enclosing case ends, as a full or read-only disk does.
local function refuse_write(suffix)
	local real_open = vim.uv.fs_open
	vim.uv.fs_open = function(p, flags, ...)
		if flags == "w" and type(p) == "string" and vim.endswith(p, suffix) then
			return nil, "ENOSPC: no space left on device (stubbed): " .. p, "ENOSPC"
		end
		return real_open(p, flags, ...)
	end
	H.defer(function()
		vim.uv.fs_open = real_open
	end)
end

-- True when a fresh listener can take port again: no server holds it.
local function port_free(port)
	local tcp, tcp_err = vim.uv.new_tcp()
	if not tcp then
		error("port_free: " .. tostring(tcp_err), 0)
	end
	local bound = tcp:bind("127.0.0.1", port)
	local listening = bound and tcp:listen(8, function() end)
	tcp:close()
	return listening == 0
end

-- One error notice whose text carries no Lua position or source path.
local function one_clean_error(notes, prefix)
	eq(#notes, 1, "one notice")
	eq(notes[1] and notes[1].level, vim.log.levels.ERROR, "the notice is an error")
	local msg = notes[1] and notes[1].msg or ""
	ok(vim.startswith(msg, prefix), "the notice begins " .. prefix .. ": " .. msg)
	ok(not msg:find(".lua:", 1, true), "the notice names no Lua position: " .. msg)
end

H.case("Section 7: a session token that cannot be made fails the start with one notice", function()
	vim.cmd("buffer " .. first_buf)
	local ls_util = require("live_server.util")
	local real_token = ls_util.random_token
	ls_util.random_token = function()
		error("random_token: no secure random source (stubbed)", 2)
	end
	H.defer(function()
		ls_util.random_token = real_token
	end)
	local notes = capture_notes()
	local ran, err = pcall(mp.start)
	ok(ran, "start() returns instead of raising: " .. tostring(err))
	one_clean_error(notes, "Markdown Preview: could not make a session token: random_token: no secure random source")
	eq(mp._server_instance, nil, "no server instance is kept")
	eq(armed(), 0, "no autocmd is armed")
	eq(mp._token, nil, "no token is kept")
end)

H.case("Section 7b: autocmds that cannot be armed stop the server and remove the lock", function()
	vim.cmd("buffer " .. first_buf)
	local port = free_port()
	mp.setup({ instance_mode = "takeover", port = port, auto_refresh_events = { "NoSuchEvent" } })
	H.defer(function()
		mp.setup({
			instance_mode = "multi",
			port = 18421,
			auto_refresh_events = { "InsertLeave", "TextChanged", "TextChangedI", "BufWritePost" },
		})
	end)
	local notes = capture_notes()
	local ran, err = pcall(mp.start)
	ok(ran, "start() returns instead of raising: " .. tostring(err))
	one_clean_error(notes, ("Markdown Preview: failed to start server (port %d): "):format(port))
	eq(mp._server_instance, nil, "no server instance is kept")
	ok(port_free(port), "the server is stopped: its port binds again")
	eq(
		vim.uv.fs_stat(vim.fs.joinpath(vim.fn.stdpath("cache"), "markdown-preview", "server.lock")),
		nil,
		"no lock is left"
	)
	eq(armed_on(first_buf), 0, "no autocmd is armed")
end)

H.case("Section 7c: content that cannot be written stops the server with one notice", function()
	vim.cmd("buffer " .. first_buf)
	local port = free_port()
	mp.setup({ port = port })
	H.defer(function()
		mp.setup({ port = 18421 })
	end)
	refuse_write("content.md")
	local notes = capture_notes()
	local ran, err = pcall(mp.start)
	ok(ran, "start() returns instead of raising: " .. tostring(err))
	one_clean_error(notes, ("Markdown Preview: failed to start server (port %d): ENOSPC"):format(port))
	eq(mp._server_instance, nil, "no server instance is kept")
	ok(port_free(port), "the server is stopped: its port binds again")
	eq(armed_on(first_buf), 0, "no autocmd is armed")
end)

H.case("Section 7d: a lock that cannot be opened stops the server with one notice", function()
	vim.cmd("buffer " .. first_buf)
	local port = free_port()
	mp.setup({ instance_mode = "takeover", port = port })
	H.defer(function()
		mp.setup({ instance_mode = "multi", port = 18421 })
	end)
	refuse_write("server.lock")
	local notes = capture_notes()
	local ran, err = pcall(mp.start)
	ok(ran, "start() returns instead of raising: " .. tostring(err))
	one_clean_error(notes, ("Markdown Preview: failed to start server (port %d): "):format(port))
	eq(mp._server_instance, nil, "no server instance is kept")
	ok(port_free(port), "the server is stopped: its port binds again")
	eq(armed_on(first_buf), 0, "no autocmd is armed")
end)

H.case("Section 7e: a retarget whose content cannot be written goes back to the served buffer", function()
	vim.cmd("buffer " .. first_buf)
	mp.start()
	H.defer(mp.stop)
	local before = mp._workspace_dir
	local port = mp._server_instance and mp._server_instance.port or 0
	vim.cmd("buffer " .. second_buf)
	refuse_write("content.md")
	local notes = capture_notes()
	local ran, err = pcall(mp.start)
	ok(ran, "start() returns instead of raising: " .. tostring(err))
	one_clean_error(notes, "Markdown Preview: could not retarget: ENOSPC")
	eq(mp._workspace_dir, before, "the workspace pointer is the one served before")
	ok(armed_on(first_buf) > 0, "the served buffer keeps its autocmds")
	eq(armed_on(second_buf), 0, "the refused buffer is not armed")
	local r = H.http_get(("http://127.0.0.1:%d/content.md?t=%s"):format(port, mp._token or ""))
	ok(
		r.status == 200 and r.body:find("# doc", 1, true) ~= nil,
		("the server serves the first buffer again: %d %s"):format(r.status, r.body)
	)
end)

H.case("Section 7f: a retarget that cannot go back either stops the server", function()
	vim.cmd("buffer " .. first_buf)
	mp.start()
	H.defer(mp.stop)
	local port = mp._server_instance and mp._server_instance.port or 0
	vim.cmd("buffer " .. second_buf)
	refuse_write("content.md")
	local real_update = ls_server.update_target
	local retargets = 0
	stub("update_target", function(...)
		retargets = retargets + 1
		if retargets > 1 then
			error("update_target: root is gone (stubbed)", 2)
		end
		return real_update(...)
	end)
	local notes = capture_notes()
	local ran, err = pcall(mp.start)
	ok(ran, "start() returns instead of raising: " .. tostring(err))
	one_clean_error(notes, "Markdown Preview: could not retarget: ENOSPC")
	ok(
		notes[1] and notes[1].msg:find("update_target: root is gone (stubbed)", 1, true),
		"the notice names the way back's refusal too"
	)
	eq(mp._server_instance, nil, "no server instance is kept")
	ok(port_free(port), "the server is stopped: its port binds again")
	eq(armed(), 0, "no autocmd is armed")
	eq(mp._workspace_dir, nil, "the workspace is cleared")
end)
calls.start, calls.stop = 0, 0

H.finish()
