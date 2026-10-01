-- lua/mdkite/util.lua
local M = {}

local sep = package.config:sub(1, 1)

local function dirname(path)
	return path:match("^(.*" .. sep .. ")") or "./"
end

function M.mkdirp(path)
	if vim.fn.isdirectory(path) == 0 then
		vim.fn.mkdir(path, "p")
	end
end

function M.file_exists(path)
	if not path then
		return false
	end
	local stat = vim.uv.fs_stat(path)
	return stat and stat.type == "file"
end

-- A rename, never a truncating open: a failed write must not empty a file being served.
function M.write_text(path, text)
	M.mkdirp(dirname(path))
	-- A rename over a link would replace the link, so the write goes to the file it names.
	local lst = vim.uv.fs_lstat(path)
	if lst and lst.type == "link" then
		local real, real_err = vim.uv.fs_realpath(path)
		-- A dangling chain: the old truncating open created the file it ends at.
		local hops = 0
		while not real do
			local named, named_err = vim.uv.fs_readlink(path)
			if not named then
				error(("%s (%s)"):format(tostring(real_err), tostring(named_err)), 0)
			end
			local absolute = named:sub(1, 1) == "/" or named:match("^%a:[/\\]") ~= nil
			path = absolute and named or vim.fs.joinpath(vim.fs.dirname(path), named)
			hops = hops + 1
			local nxt = vim.uv.fs_lstat(path)
			if not (nxt and nxt.type == "link") then
				real = path
			elseif hops >= 40 then
				error(("%s: too many links"):format(path), 0)
			end
		end
		path = real
	end
	local target = vim.uv.fs_stat(path)
	-- Dot-named, so kitehost neither serves nor watches it while it exists.
	local tmp = vim.fs.joinpath(vim.fs.dirname(path), (".%s.%d.tmp"):format(vim.fs.basename(path), vim.uv.os_getpid()))
	local function fail(err)
		-- luv names the temporary, which a user never chose: name the target.
		local text = tostring(err)
		local at, to = text:find(tmp, 1, true)
		err = at and (text:sub(1, at - 1) .. path .. text:sub(to + 1)) or text
		local removed, remove_err = vim.uv.fs_unlink(tmp)
		if not removed and not tostring(remove_err):find("ENOENT", 1, true) then
			err = ("%s (and %s is left: %s)"):format(tostring(err), tmp, tostring(remove_err))
		end
		error(tostring(err), 0)
	end
	local fd, open_err = vim.uv.fs_open(tmp, "w", 420) -- 0644
	if not fd then
		fail(open_err)
	end
	local wrote, write_err = vim.uv.fs_write(fd, text, 0)
	if wrote ~= #text then
		vim.uv.fs_close(fd)
		fail(wrote and ("short write: %d of %d bytes"):format(wrote, #text) or write_err)
	end
	local closed, close_err = vim.uv.fs_close(fd)
	if not closed then
		fail(close_err)
	end
	-- The rename would give the target the temporary's mode, a 0600 file 0644.
	if target then
		local kept, chmod_err = vim.uv.fs_chmod(tmp, target.mode % 4096)
		if not kept then
			fail(chmod_err)
		end
	end
	local renamed, rename_err = vim.uv.fs_rename(tmp, path)
	if not renamed then
		fail(rename_err)
	end
end

-- Raises at level 0 as write_text does: the start notice carries its reason.
function M.read_text(path)
	if type(path) ~= "string" or path == "" then
		error("read_text: path is nil", 0)
	end
	local fd, open_err = vim.uv.fs_open(path, "r", 420)
	if not fd then
		error(tostring(open_err), 0)
	end
	local stat, stat_err = vim.uv.fs_fstat(fd)
	local data, read_err
	if stat then
		data, read_err = vim.uv.fs_read(fd, stat.size, 0)
	end
	local closed, close_err = vim.uv.fs_close(fd)
	if not stat then
		error(tostring(stat_err), 0)
	end
	if not data then
		error(tostring(read_err), 0)
	end
	if not closed then
		error(tostring(close_err), 0)
	end
	return data
end

function M.copy_file(src, dst)
	assert(type(src) == "string" and #src > 0, "copy_file: source path is nil")
	local data = M.read_text(src)
	M.write_text(dst, data)
end

---Resolve a file shipped with the plugin using runtimepath first.
---@param rel string
---@return string|nil
function M.resolve_asset(rel)
	-- Prefer runtimepath discovery (robust across plugin managers and symlinks)
	local hits = vim.api.nvim_get_runtime_file(rel, false)
	if hits and #hits > 0 then
		return hits[1]
	end

	-- Fallback to path math from this file location
	local info = debug.getinfo(1, "S")
	local this = type(info.source) == "string" and info.source or ""
	if this:sub(1, 1) == "@" then
		this = this:sub(2)
	end
	-- The path keeps the separators of the runtimepath entry it loaded
	-- through, a slash on Windows too where a plugin manager wrote one, so
	-- either ends a directory; a slash join opens on every OS.
	local root = this:match("^(.-)[/\\]lua[/\\]mdkite[/\\]util%.lua$")
	if root then
		local candidate = vim.fs.joinpath(root, rel)
		if M.file_exists(candidate) then
			return candidate
		end
	end
	return nil
end

---Launch a detached command; true when the process spawned.
---(vim.fn.jobstart raises for a non-executable command, so pcall it.)
local function try_launch(cmd, opts)
	local ok, job = pcall(vim.fn.jobstart, cmd, opts or { detach = true })
	return ok and job > 0
end

---Open a URL in the browser.
---@param url string
---@param browser string|table|nil Optional override. String = browser name/binary.
---  Table = full command (URL appended). nil = system default.
function M.open_in_browser(url, browser)
	local function warn(what)
		vim.notify(("mdkite: %s.\nOpen manually: %s"):format(what, url), vim.log.levels.WARN)
	end

	if browser then
		local cmd
		local opts = { detach = true }
		if type(browser) == "table" then
			cmd = vim.list_extend(vim.deepcopy(browser), { url })
		elseif vim.fn.has("mac") == 1 then
			-- On macOS, `open -a` resolves app names like "Firefox" or
			-- "Google Chrome". The spawn succeeds even when the app doesn't
			-- exist (`open` itself exits non-zero), so check the exit code.
			cmd = { "open", "-a", browser, url }
			opts.on_exit = function(_, code)
				if code ~= 0 then
					vim.schedule(function()
						warn(('configured browser "%s" could not be opened'):format(browser))
					end)
				end
			end
		else
			cmd = { browser, url }
		end
		if not try_launch(cmd, opts) then
			warn(
				("could not launch configured browser (%s)"):format(type(browser) == "table" and browser[1] or browser)
			)
		end
		return
	end

	local candidates
	if vim.fn.has("mac") == 1 then
		candidates = { { "open", url } }
	elseif vim.fn.has("wsl") == 1 then
		-- WSL: Windows interop may be disabled or off PATH (issue #26), so
		-- try the usual launchers in order instead of assuming one works.
		candidates = {
			{ "wslview", url },
			{ "explorer.exe", url },
			{ "powershell.exe", "-NoProfile", "-Command", "Start-Process '" .. url .. "'" },
		}
	elseif vim.fn.has("unix") == 1 then
		candidates = { { "xdg-open", url } }
	elseif vim.fn.has("win32") == 1 then
		candidates = { { "cmd.exe", "/c", "start", url } }
	else
		candidates = {}
	end

	for _, cmd in ipairs(candidates) do
		if vim.fn.executable(cmd[1]) == 1 and try_launch(cmd) then
			return
		end
	end
	warn("could not open a browser automatically")
end

---The directory under Neovim's cache that holds the workspaces and the lock.
---@return string
function M.cache_dir()
	return vim.fs.joinpath(vim.fn.stdpath("cache"), "mdkite")
end

---Generate a per-buffer workspace directory under Neovim's cache.
---@param bufnr integer
---@return string
function M.workspace_for_buffer(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	local hash = vim.fn.sha256(name):sub(1, 12)
	return vim.fs.joinpath(M.cache_dir(), hash)
end

function M.shared_workspace()
	return vim.fs.joinpath(M.cache_dir(), "shared")
end

return M
