-- tests/start_failure_test.lua
-- A start that fails leaves nothing behind: no autocmd refreshing a
-- preview that does not exist, no token or workspace kept, no lock, no
-- on_start; the notification names the port and what to do. Section 1
-- stubs live-server's start to raise and Section 1b the lock's write, so
-- they hold on every live-server the plugin runs on, the pinned floor
-- included. A retarget, a reload and a scroll push that live-server
-- refuses are each told through the plugin's own notice.
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
start_raising("cannot listen on 127.0.0.1:18421: EADDRINUSE: address already in use")
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
	ok(notes[1] and notes[1].msg:find("live reload is off", 1, true), "the notice says live reload is off")
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

H.finish()
