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
H.rtp()

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

-- The plugin's autocmds on one buffer.
local function armed_on(bufnr)
	local n = 0
	for _, au in ipairs(vim.api.nvim_get_autocmds({ group = "MarkdownPreviewAuto" })) do
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

-- A port another program listens on, for the start to meet the real refusal.
local function held_port(addr)
	local tcp = vim.uv.new_tcp()
	local bound, bind_err = tcp:bind(addr, 0)
	if not bound then
		error("held_port: " .. tostring(bind_err), 0)
	end
	local listening, listen_err = tcp:listen(8, function() end)
	if not listening then
		error("held_port: " .. tostring(listen_err), 0)
	end
	H.defer(function()
		tcp:close()
	end)
	return tcp:getsockname().port
end

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

H.finish()
