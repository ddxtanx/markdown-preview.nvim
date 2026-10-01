-- tests/asset_route_test.lua
-- The relative-image promise of v1.10.0 rides on kitehost's asset route.
-- The suite passed against live-server v1.4.0, which has no such route, so
-- the first check names the feature flag and the rest drive the route; the
-- plugin's asset_root sidecar, which names the document's directory, stays
-- behind the token. The bundled index resolves from the module's own path
-- when the runtimepath has no copy.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/asset_route_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local uv = vim.uv

local server = require("kitehost.server")

H.section("Section 1: the installed kitehost is at or above the floor")
-- The route's own flag, and the two a start refuses a server without.
H.ok(
	type(server.features) == "table"
		and server.features.asset_route == true
		and server.features.host_check == true
		and server.features.start_raises == true,
	("kitehost exports features.asset_route, host_check and start_raises (%s or newer)"):format(H.kitehost_floor)
)

local dir = H.tmpdir()
H.write_file(dir .. "/pic.png", "PNGDATA")
H.write_file(vim.fs.dirname(dir) .. "/outside.txt", "SECRET")
local md = dir .. "/doc.md"
H.write_file(md, "# pics\n\n![](pic.png)\n")
vim.cmd("edit " .. vim.fn.fnameescape(md))
vim.bo.filetype = "markdown"

local mp = require("mdkite")
mp.setup({ open_browser = false, instance_mode = "multi" })
mp.start()

H.section("Section 2: the asset route serves files beside the document")
local base = ("http://127.0.0.1:%d"):format(mp._server_instance.port)
H.eq(H.http_get(base .. "/__live/asset?p=pic.png").status, 401, "asset without the token is 401")
H.eq(H.http_get(base .. "/__live/asset?p=pic.png&t=wrong").status, 401, "asset with a wrong token is 401")
local r = H.http_get(base .. "/__live/asset?p=pic.png&t=" .. mp._token)
H.eq(r.status, 200, "asset with the token is 200")
H.eq(r.body, "PNGDATA", "asset body is the file beside the document")
H.eq(
	H.http_get(base .. "/__live/asset?p=../outside.txt&t=" .. mp._token).status,
	404,
	"a path above the document's directory is 404"
)
-- Containment is by the resolved path, not the spelling: a lexical check
-- served a link like this one (measured on a mutant of the server). The
-- target is written with the platform's separator, since Windows took a /
-- in it unconverted and the link did not resolve (measured on the hosted
-- runner); a link that cannot be made or does not resolve proves nothing
-- and is skipped, counted.
local linked, link_err = uv.fs_symlink(".." .. package.config:sub(1, 1) .. "outside.txt", dir .. "/link.txt")
if linked and uv.fs_stat(dir .. "/link.txt") then
	H.eq(
		H.http_get(base .. "/__live/asset?p=link.txt&t=" .. mp._token).status,
		404,
		"a symlink beside the document pointing above it is 404"
	)
else
	H.skip(
		"a symlink beside the document pointing above it is 404 ("
			.. tostring(link_err or "the link does not resolve")
			.. ")"
	)
end

H.section("Section 3: the asset_root sidecar is gated")
-- Ungated, it hands any client the document's absolute directory (measured).
H.eq(H.http_get(base .. "/asset_root").status, 401, "the asset_root sidecar without the token is 401")

mp.stop()

H.section("Section 4: the bundled index resolves without the runtimepath")
-- The runtimepath answers first wherever the checkout is on it, so only a
-- search that finds nothing reaches the root cut from the module's own
-- path, where a pattern naming the wrong directory fails no start.
local real_runtime_file = vim.api.nvim_get_runtime_file
vim.api.nvim_get_runtime_file = function()
	return {}
end
local found_ok, found = pcall(require("mdkite.util").resolve_asset, "assets/index.html")
vim.api.nvim_get_runtime_file = real_runtime_file
H.ok(
	found_ok and type(found) == "string" and H.same_path(found, H.root .. "/assets/index.html"),
	"assets/index.html resolves from the module's own path: " .. tostring(found)
)
-- The module's path keeps its runtimepath entry's separators, and the
-- hosted Windows runner spells that entry with slashes, where a cut on the
-- platform's backslash found no root (measured); either spelling, read
-- here on every OS, must reach the checkout. The stub answers the one
-- getinfo call resolve_asset makes for its own source.
local util = require("mdkite.util")
local real_getinfo = debug.getinfo
for _, slash in ipairs({ "/", "\\" }) do
	local source = "@" .. H.root .. slash .. table.concat({ "lua", "mdkite", "util.lua" }, slash)
	vim.api.nvim_get_runtime_file = function()
		return {}
	end
	debug.getinfo = function(level, what)
		if level ~= 1 or what ~= "S" then
			error("the getinfo stub answers resolve_asset's own source read only", 2)
		end
		return { source = source }
	end
	local cut_ok, cut = pcall(util.resolve_asset, "assets/index.html")
	debug.getinfo = real_getinfo
	vim.api.nvim_get_runtime_file = real_runtime_file
	H.ok(
		cut_ok and type(cut) == "string" and H.same_path(cut, H.root .. "/assets/index.html"),
		("a module path whose separator is %s resolves the index from its root: %s"):format(slash, tostring(cut))
	)
end
H.finish()
