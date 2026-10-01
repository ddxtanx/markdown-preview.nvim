-- lua/mdkite/lock.lua
local uv = vim.uv
local util = require("mdkite.util")

local M = {}

local function lock_path()
	return vim.fs.joinpath(util.cache_dir(), "server.lock")
end

-- The lock the releases before the rename keep under their own cache
-- directory, read through the 2.x releases so a preview one of them runs is
-- found; nothing here writes or removes it.
local function old_lock_path()
	return vim.fs.joinpath(vim.fn.stdpath("cache"), "markdown-preview", "server.lock")
end

local function read_at(path)
	local fd = uv.fs_open(path, "r", 420)
	if not fd then
		return nil
	end
	local stat = uv.fs_fstat(fd)
	if not stat then
		uv.fs_close(fd)
		return nil
	end
	local data = uv.fs_read(fd, stat.size, 0)
	uv.fs_close(fd)
	if not data then
		return nil
	end
	local ok, tbl = pcall(vim.json.decode, data)
	if not ok or type(tbl) ~= "table" then
		return nil
	end
	-- The probe and the pushes hand the port to luv, which raises on a non-number.
	local port = tbl.port
	if type(port) ~= "number" or port % 1 ~= 0 or port < 1 or port > 65535 then
		return nil
	end
	return tbl
end

function M.read()
	return read_at(lock_path())
end

function M.read_old()
	return read_at(old_lock_path())
end

-- Both releases take port 8421 in takeover, so the server answering on a
-- lock's port may be the other release's: a lock counts only while the
-- process it names runs too. Signal 0 sends nothing; ESRCH says the process
-- is gone, and EPERM that it runs under another account. A lock without a
-- usable pid, or a check that fails another way, leaves the probe alone to
-- decide, as before.
local function held(lock)
	local pid = lock.pid
	if type(pid) == "number" and pid % 1 == 0 and pid >= 1 and pid <= 2147483647 then
		local sent, err, name = uv.kill(pid, 0)
		if not sent and (name or tostring(err):match("^%u+")) == "ESRCH" then
			return false
		end
	end
	return M.is_server_alive(lock.port)
end

-- The lock whose holder runs and answers, and whether it is the old one:
-- this release's first, then the old one, so a stale lock under either name
-- counts for nothing. Read and probed through M, where a test replaces them.
function M.holder()
	local current = M.read()
	if current and held(current) then
		return current, false
	end
	local old = M.read_old()
	if old and held(old) then
		return old, true
	end
	return nil
end

function M.write(port, workspace, token, host)
	local path = lock_path()
	local dir = path:match("^(.+)/[^/]+$")
	if dir and vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	local json = vim.json.encode({
		port = port,
		workspace = workspace,
		pid = vim.fn.getpid(),
		token = token, -- nil OK; secondary instances need this to hit /__live/inject
		host = host, -- the bind, which decides whether a secondary's URL carries the token
	})
	-- Mode 0600 (decimal 384) so the token isn't world-readable on multi-user
	-- systems. The open applies the mode only when it creates the file (a
	-- direct call on an existing 0644 file kept that mode through the
	-- truncate, measured, and a primary writes over a stale lock); fchmod
	-- makes the file private before the token is written, and a file that
	-- cannot be made private gets no token.
	-- Level 0: LuaJIT's assert would put this file's position in the notice.
	local fd, open_err = uv.fs_open(path, "w", 384)
	if not fd then
		error("cannot open the lock file: " .. tostring(open_err), 0)
	end
	local private, chmod_err = uv.fs_fchmod(fd, 384)
	if not private then
		uv.fs_close(fd)
		error("cannot make the lock file private: " .. tostring(chmod_err), 0)
	end
	local wrote, write_err = uv.fs_write(fd, json, 0)
	if not wrote then
		uv.fs_close(fd)
		error("cannot write the lock file: " .. tostring(write_err), 0)
	end
	local closed, close_err = uv.fs_close(fd)
	if not closed then
		error("cannot close the lock file: " .. tostring(close_err), 0)
	end
end

function M.remove()
	pcall(uv.fs_unlink, lock_path())
end

function M.is_server_alive(port)
	local alive = nil
	local tcp = uv.new_tcp()
	tcp:connect("127.0.0.1", port, function(err)
		alive = not err
		pcall(function()
			tcp:shutdown()
		end)
		pcall(function()
			tcp:close()
		end)
	end)
	vim.wait(500, function()
		return alive ~= nil
	end, 10)
	if alive == nil then
		pcall(function()
			tcp:close()
		end)
		alive = false
	end
	return alive
end

return M
