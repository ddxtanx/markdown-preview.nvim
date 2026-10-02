-- tests/rtp_test.lua
-- Pin how H.rtp() proves the checkout and finds kitehost.nvim: an override
-- that is not a directory, a missing dependency, and a checkout or a
-- directory the runtimepath does not resolve to raise instead of letting
-- require fall through to an installed copy, each naming its reason; the
-- chosen directory beats an installed copy, KITEHOST_RTP beats
-- LIVE_SERVER_RTP (its name before 2.0.0, read through 2.x), ./kitehost-rtp
-- beats the sibling clone, which beats the sibling under its name before
-- 2.0.0, a directory reached through a plain-named link loads by that name,
-- a stray dotted Lua file in the checkout is no module, and the path it
-- returns is canonical. Every expected path is built through H.canon too, so
-- an 8.3 name or a backslash on Windows, or /var against /private/var on
-- macOS, never reads as a different file.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/rtp_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
-- The kitehost this run found, for the cases that need a real one; every
-- other case runs H.rtp() in a child, so a raise here is caught, not fatal.
local found_ok, real_kitehost = pcall(H.rtp)

local uv = vim.uv
local ok, eq = H.ok, H.eq

-- One child of the same binary per case, since a raise ends the process that
-- runs it. Every child gets KITEHOST_RTP, the override, and LIVE_SERVER_RTP,
-- empty unless env sets it (empty reads as unset), so neither value in the
-- caller's environment leaks into a case; vim.system reports a
-- child killed at the bound as exit 124, and one killed by a signal as code
-- 0, which H.exit_code reads as 128 + the signal. A child loads the helper
-- by the name this suite loaded it through, not by H.root: H.rtp puts the
-- checkout on the runtimepath by that name, and through a plain-named link
-- to a directory whose real name carries a comma the canonical one splits.
-- Made absolute the way the helper makes its own name absolute (:p keeps an
-- absolute link name as it is), since a child runs with its own cwd.
local helpers_path =
	vim.fn.fnamemodify(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"), ":p")
local CHILD_TIMEOUT_MS = 30000
local function child(helpers, body, override, env, cwd)
	local path = vim.fs.joinpath(H.tmpdir(), "child_test.lua")
	H.write_file(path, ("local H = dofile(%q)\n%s\n"):format(helpers, body))
	local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", path }, {
		env = vim.tbl_extend("force", { LIVE_SERVER_RTP = "" }, env or {}, { KITEHOST_RTP = override }),
		cwd = cwd,
		timeout = CHILD_TIMEOUT_MS,
	}):wait()
	return H.exit_code(r), (r.stdout or "") .. (r.stderr or "")
end

-- The child's exit code when its output carries text (every one of them,
-- when text is a list), else what went wrong.
local function ruling(code, out, text)
	if code == 124 then
		return ("killed after %d ms"):format(CHILD_TIMEOUT_MS)
	end
	for _, want in ipairs(type(text) == "table" and text or { text }) do
		if not out:find(want, 1, true) then
			return ("exit %d without %q"):format(code, want)
		end
	end
	return code
end

-- The reasons H.rtp's refusals give, written out here, so a reason that
-- changes, or one swapped for another, reds the cases that name it: the
-- checkout's own, and kitehost's, which adds the files it needs.
local RTP_SYNTAX =
	"a name the runtimepath reads differently (a comma, a dollar sign, a glob character, a backslash, a brace, or a name ending in after)"
local KH_REASON = "(a directory without lua/kitehost/server.lua and util.lua, or " .. RTP_SYNTAX .. ")"

-- A child that must succeed: its exit is asserted as child() reads it, so
-- expected output printed before a timeout (124) or a death by signal (128
-- + the signal, where vim.system's own code reads 0) cannot pass the case.
-- Returns the output.
local function succeeded(msg, helpers, body, override, env, cwd)
	local code, out = child(helpers, body, override, env, cwd)
	eq(code, 0, msg .. ": the child exits 0")
	return out
end

-- The value a child wrote after "name=". Children write such lines through
-- H.write_line: on 0.12.5 a print line whose path made it a multiple of 80
-- columns fused with the next one (measured).
local function printed(out, name)
	return out:match(name .. "=([^\r\n]*)")
end

-- The file a child's require loaded, canonical: debug.getinfo gives it with
-- "@" before the runtimepath entry as the search path spelled it (with
-- backslashes on Windows).
local function loaded(out)
	local source = printed(out, "source")
	return source and H.canon((source:gsub("^@", "")))
end

-- kitehost's modules under root (both unless files names some), enough for
-- the lookup and for require; the path in a loaded source names the copy.
local function stub(root, files)
	vim.fn.mkdir(root .. "/lua/kitehost", "p")
	for _, name in ipairs(files or { "server", "util" }) do
		H.write_file(root .. "/lua/kitehost/" .. name .. ".lua", "return { start = function() end }\n")
	end
end

-- A checkout of this plugin under root, holding a copy of the helper and the
-- entry file its root proof resolves; returns the copy's path.
local function tree(root)
	vim.fn.mkdir(root .. "/tests", "p")
	vim.fn.mkdir(root .. "/lua/mdkite", "p")
	assert(uv.fs_copyfile(helpers_path, root .. "/tests/helpers.lua"))
	H.write_file(root .. "/lua/mdkite/init.lua", "return {}\n")
	return root .. "/tests/helpers.lua"
end

-- One skip per assertion a case would have made, each named as it would have
-- been: msg followed by each suffix ("" is msg itself).
local function skip_each(msg, suffixes, why)
	for _, suffix in ipairs(suffixes) do
		H.skip(msg .. suffix .. " (" .. why .. ")")
	end
end
-- The assertions a case makes: one eq named msg, or succeeded()'s exit check
-- and then one named msg.
local ONE = { "" }
local CHILD_AND_ONE = { ": the child exits 0", "" }

-- The runtimepath reads a comma, a dollar sign or a glob character in an
-- entry as syntax, so a fixture under a temp path carrying one proves nothing
-- (measured with a comma in TMPDIR): such a run skips each of the case's
-- assertions, counted, as suffixes lists them.
local base = H.tmpdir()
local odd_temp = base:find("[,$*?%[%]{}]") ~= nil
local function fixture(msg, suffixes, fn)
	if odd_temp then
		skip_each(msg, suffixes, "the temp path " .. base .. " carries a comma, a dollar sign or a glob character")
		return
	end
	fn(msg)
end

-- A start package on the child's own packpath: its data directory is
-- nvim-data on Windows and follows NVIM_APPNAME, so the child reports it.
local data = base .. "/data"
local child_data = printed(
	succeeded(
		"the child reports its data directory",
		helpers_path,
		[[
H.write_line("data=" .. vim.fn.stdpath("data"))
H.ok(true, "reported")
H.finish()]],
		"",
		{ XDG_DATA_HOME = data }
	),
	"data"
)
local installed = child_data .. "/site/pack/t/start/installed"
stub(installed)

-- A child killed by a signal after its output must not read as the 0
-- vim.system reports for it. SIGKILL, since Neovim catches SIGTERM and exits
-- 1 through its own handler (measured on 0.10.0 and 0.12.5).
if vim.fn.has("win32") == 1 then
	H.skip("a child killed by SIGKILL after its output reads 137 (no POSIX signal on Windows)")
else
	local killed = child(
		helpers_path,
		[[
H.ok(true, "x")
H.finish()
io.stdout:write("written before the kill\n")
io.stdout:flush()
local uv = vim.uv
uv.kill(uv.os_getpid(), "sigkill")]],
		""
	)
	eq(killed, 137, "a child killed by SIGKILL after its output reads 137")
end

H.section("Section 1: a lookup that cannot be proven raises")
local code, out = child(helpers_path, "H.rtp()", "/nonexistent")
eq(
	ruling(code, out, "child_test.lua:2: KITEHOST_RTP is set but is not a directory: /nonexistent"),
	1,
	"an override that is not a directory raises at the suite's line"
)
-- The override's name before 2.0.0 is read through 2.x when KITEHOST_RTP
-- is unset, and its refusal names the variable that was set.
code, out = child(helpers_path, "H.rtp()", "", { LIVE_SERVER_RTP = "/nonexistent" })
eq(
	ruling(code, out, "child_test.lua:2: LIVE_SERVER_RTP is set but is not a directory: /nonexistent"),
	1,
	"LIVE_SERVER_RTP, read when KITEHOST_RTP is unset, raises naming itself when it is not a directory"
)

-- H.root follows the helper's own path, so a copy of it in a tree with no
-- ./kitehost-rtp and no sibling clone under either name finds nothing; the
-- message names where to clone from, the floor and both paths, canonical.
fixture("no candidate on any lookup path raises, naming the clone, the floor and both paths", ONE, function(msg)
	local bare = base .. "/bare/mp"
	code, out = child(tree(bare), "H.rtp()", "")
	eq(
		ruling(
			code,
			out,
			("child_test.lua:2: kitehost.nvim not found: clone https://github.com/selimacerbas/kitehost.nvim (%s or newer) to %s/kitehost-rtp or %s/kitehost.nvim, or set KITEHOST_RTP to a checkout"):format(
				H.kitehost_floor,
				H.canon(bare),
				H.canon(base .. "/bare")
			)
		),
		1,
		msg
	)
end)

code, out = child(helpers_path, "H.rtp()", H.tmpdir())
eq(ruling(code, out, { "does not resolve: ", " " .. KH_REASON }), 1, "an empty override directory raises")

-- The runtimepath expands $HOME in the entry when it searches, so the stub
-- under the literal name is never the one resolved (measured) and require
-- would load the start package; the refusal names both.
fixture("an override with a $ in its name raises, naming the shadowing copy", ONE, function(msg)
	local odd = base .. "/odd$HOME-x"
	-- A file system that refuses the name skips the case, measured by the
	-- mkdir itself rather than by the platform (NTFS takes a $).
	local made, err = uv.fs_mkdir(odd, 493)
	if not made then
		H.skip(msg .. " (this file system refuses the name: " .. tostring(err) .. ")")
		return
	end
	stub(odd)
	code, out = child(helpers_path, "H.rtp()", odd, { XDG_DATA_HOME = data })
	eq(
		ruling(
			code,
			out,
			("kitehost.nvim at %s does not resolve: %s/lua/kitehost/server.lua"):format(
				H.canon(base) .. "/odd$HOME-x",
				H.canon(installed)
			)
				.. " "
				.. KH_REASON
		),
		1,
		msg
	)
end)

-- An override above a start package: the search resolves the package's
-- server.lua, whose path starts with the override's, so only equality with
-- the override's own file refuses it.
fixture("an override that holds an installed copy below it raises", ONE, function(msg)
	code, out = child(helpers_path, "H.rtp()", data, { XDG_DATA_HOME = data })
	eq(
		ruling(
			code,
			out,
			("kitehost.nvim at %s does not resolve: %s/lua/kitehost/server.lua"):format(
				H.canon(data),
				H.canon(installed)
			)
				.. " "
				.. KH_REASON
		),
		1,
		msg
	)
end)

-- The plugin and server.lua both require util, so a directory holding
-- server.lua alone would load util from the start package (measured).
fixture("an override without util.lua raises, naming the copy util resolves to", ONE, function(msg)
	local partial = base .. "/partial"
	stub(partial, { "server" })
	code, out = child(helpers_path, "H.rtp()", partial, { XDG_DATA_HOME = data })
	eq(
		ruling(
			code,
			out,
			("kitehost.nvim at %s does not resolve: %s/lua/kitehost/util.lua"):format(
				H.canon(partial),
				H.canon(installed)
			)
				.. " "
				.. KH_REASON
		),
		1,
		msg
	)
end)

-- A comma in the checkout's own path splits its entry, and require loaded an
-- installed copy of this plugin instead of the checkout (measured).
fixture("a checkout whose path the runtimepath splits raises, naming the installed copy", ONE, function(msg)
	local split = base .. "/a,b/mp"
	local installed_mp = child_data .. "/site/pack/t/start/installed-mp"
	vim.fn.mkdir(installed_mp .. "/lua/mdkite", "p")
	H.write_file(installed_mp .. "/lua/mdkite/init.lua", "return {}\n")
	code, out = child(tree(split), "H.rtp()", "", { XDG_DATA_HOME = data })
	eq(
		ruling(
			code,
			out,
			("the checkout at %s does not resolve: %s/lua/mdkite/init.lua"):format(
				H.canon(split),
				H.canon(installed_mp)
			)
				.. " ("
				.. RTP_SYNTAX
				.. ")"
		),
		1,
		msg
	)
end)

-- The kitehost directory goes before the checkout on the runtimepath, so
-- one that also carries this plugin's modules answered require while every
-- proof passed (measured); the root is proven again after the prepend.
fixture("a kitehost directory that carries this plugin's modules raises, naming them", ONE, function(msg)
	local dep = base .. "/dep"
	stub(dep)
	vim.fn.mkdir(dep .. "/lua/mdkite", "p")
	H.write_file(dep .. "/lua/mdkite/init.lua", 'error("DEP COPY OF mdkite LOADED")\n')
	code, out = child(helpers_path, 'H.rtp()\nrequire("mdkite")\nH.ok(true, "loaded")\nH.finish()', dep)
	eq(
		ruling(
			code,
			out,
			("child_test.lua:2: the checkout at %s does not resolve: %s/lua/mdkite/init.lua (kitehost.nvim at %s carries this plugin's modules too)"):format(
				H.root,
				H.canon(dep),
				H.canon(dep)
			)
		),
		1,
		msg
	)
end)

-- The loader tries lua/<mod>.lua before lua/<mod>/init.lua in each entry,
-- and the kitehost directory comes first, so a flat file there, or a
-- submodule the checkout ships, answered require while a proof of init.lua
-- alone passed (measured); the module's name before the rename is such a
-- flat file through 2.x. H.rtp raises before any require runs.
for _, shadow in ipairs({ "lua/mdkite.lua", "lua/mdkite/lock/init.lua", "lua/markdown_preview.lua" }) do
	fixture("a kitehost directory carrying " .. shadow .. " raises, naming it", ONE, function(msg)
		local dep = base .. "/shadow-" .. shadow:gsub("[/.]", "-")
		stub(dep)
		vim.fn.mkdir(vim.fs.dirname(dep .. "/" .. shadow), "p")
		H.write_file(dep .. "/" .. shadow, 'error("SHADOW COPY LOADED")\n')
		code, out = child(
			helpers_path,
			'H.rtp()\nrequire("mdkite")\nrequire("mdkite.lock")\nrequire("markdown_preview")\nH.ok(true, "loaded")\nH.finish()',
			dep
		)
		eq(
			ruling(
				code,
				out,
				("the checkout at %s does not resolve: %s/%s (kitehost.nvim at %s carries this plugin's modules too)"):format(
					H.root,
					H.canon(dep),
					shadow,
					H.canon(dep)
				)
			),
			1,
			msg
		)
	end)
end

-- A last component named after makes the entry an after-directory, searched
-- after every other, so the start package answers for it (measured); the
-- refusal names kitehost's reason.
fixture("a kitehost directory named after raises, naming the copy require would load", ONE, function(msg)
	local after = base .. "/x/after"
	stub(after)
	code, out = child(helpers_path, "H.rtp()", after, { XDG_DATA_HOME = data })
	eq(
		ruling(
			code,
			out,
			("kitehost.nvim at %s does not resolve: %s/lua/kitehost/server.lua"):format(
				H.canon(after),
				H.canon(installed)
			)
				.. " "
				.. KH_REASON
		),
		1,
		msg
	)
end)

-- A brace group with a comma makes building the search path raise E220
-- here (measured), which the refusal names with kitehost's reason. The
-- hosted Windows runner drops the entry instead, a glob that matches
-- nothing, with no error (measured), so the proof finds no hit and the
-- refusal names the reason: the same refusal, reached another way. A
-- runtimepath that reads the brace literally loads the directory, a
-- counted skip; any other outcome stays red with the child's output.
fixture("a kitehost directory with a brace group raises the search's own error", ONE, function(msg)
	local braced = base .. "/d{a,b}"
	stub(braced)
	code, out = child(helpers_path, 'H.rtp()\nH.write_line("loaded=yes")\nH.ok(true, "loaded")\nH.finish()', braced)
	local dropped = ("child_test.lua:2: kitehost.nvim at %s does not resolve: nil "):format(H.canon(braced))
		.. KH_REASON
	if out:find("E220", 1, true) then
		eq(
			ruling(code, out, {
				("child_test.lua:2: kitehost.nvim at %s does not resolve: the runtimepath raised "):format(
					H.canon(braced)
				),
				" " .. KH_REASON,
			}),
			1,
			msg
		)
	elseif out:find(dropped, 1, true) then
		eq(
			ruling(code, out, dropped),
			1,
			msg .. " (the runtimepath drops the entry here: the proof's refusal, no E220)"
		)
	elseif code == 0 and printed(out, "loaded") == "yes" then
		H.skip(msg .. " (the runtimepath reads the brace literally here: the directory loaded without E220)")
	else
		eq(("exit %s without E220 or the proof's refusal: %s"):format(code, vim.inspect(out)), 1, msg)
	end
end)

H.section("Section 2: the directory H.rtp() chooses and the path it returns")
local plain = base .. "/plain"
stub(plain)
-- git mergetool leaves util.BASE.12345.lua beside util.lua during a
-- conflict; no require names it, so the proof skips it where it once
-- failed every suite with a reason that named no conflict.
fixture("a checkout holding a stray dotted Lua file loads", ONE, function(msg)
	local stray = base .. "/stray/mp"
	local helpers = tree(stray)
	H.write_file(stray .. "/lua/mdkite/util.BASE.12345.lua", "return {}\n")
	code, out = child(helpers, 'H.rtp()\nH.ok(true, "loaded")\nH.finish()', plain)
	eq(ruling(code, out, "Results: 1 passed, 0 failed, 0 skipped"), 0, msg)
end)
-- The .. resolves through the filesystem, as the directory check read it,
-- and the path comes back canonical (on macOS /private/var, not /var).
fixture("an override reached through .. comes back normalized", CHILD_AND_ONE, function(msg)
	vim.fn.mkdir(base .. "/sub", "p")
	out = succeeded(
		msg,
		helpers_path,
		'H.write_line("found=" .. H.rtp())\nH.ok(true, "reached")\nH.finish()',
		base .. "/sub/../plain"
	)
	eq(printed(out, "found"), H.canon(base .. "/plain"), msg)
end)

-- Resolved against the child's working directory, which Windows keeps in
-- the 8.3 form the parent gave it (the first hosted run), so both sides are
-- canonical.
fixture("a relative override comes back absolute", CHILD_AND_ONE, function(msg)
	out = succeeded(
		msg,
		helpers_path,
		'H.write_line("found=" .. H.rtp())\nH.ok(true, "reached")\nH.finish()',
		"plain",
		nil,
		base
	)
	eq(printed(out, "found"), H.canon(base .. "/plain"), msg)
end)

-- An absolute override under the temp root comes back as the filesystem
-- names it (/private/var on macOS, the long name on Windows), not as typed.
fixture("an absolute override comes back canonical", CHILD_AND_ONE, function(msg)
	out = succeeded(
		msg,
		helpers_path,
		'H.write_line("found=" .. H.rtp())\nH.ok(true, "reached")\nH.finish()',
		base .. "/plain"
	)
	eq(printed(out, "found"), H.canon(base .. "/plain"), msg)
end)

fixture("a symlinked checkout finds its physical sibling", CHILD_AND_ONE, function(msg)
	local phys = base .. "/phys"
	tree(phys .. "/mp")
	stub(phys .. "/kitehost.nvim")
	vim.fn.mkdir(base .. "/links", "p")
	local link = base .. "/links/mp"
	-- Windows makes a file link unless told dir, and a file link to a
	-- directory cannot be entered (the likely cause of the first hosted run's
	-- exit 1); elsewhere the flag is ignored. A platform that refuses the link,
	-- or a link the helper cannot be read through, skips both assertions, each
	-- counted.
	local linked, err = uv.fs_symlink(phys .. "/mp", link, { dir = true })
	if not (linked and uv.fs_stat(link .. "/tests/helpers.lua")) then
		skip_each(msg, CHILD_AND_ONE, "no directory symlink here: " .. tostring(err or "the link does not resolve"))
		return
	end
	out = succeeded(
		msg,
		link .. "/tests/helpers.lua",
		'H.write_line("found=" .. H.rtp())\nH.ok(true, "reached")\nH.finish()',
		""
	)
	eq(printed(out, "found"), H.canon(phys .. "/kitehost.nvim"), msg)
end)

-- The runtimepath gets kitehost by the name it was found under, so a
-- plain-named link to a directory whose real name carries a comma loads,
-- where the physical name would be split; the printed path and the file
-- require loads are the canonical target.
local PLAIN_LINK = { ": the child exits 0", ": the printed line names the target", ": require loads it" }
fixture("an override through a plain-named link to a path with a comma loads", PLAIN_LINK, function(msg)
	local target = base .. "/co,mma-kh"
	stub(target)
	local link = base .. "/plain-link"
	local linked, err = uv.fs_symlink(target, link, { dir = true })
	if not (linked and uv.fs_stat(link .. "/lua/kitehost/server.lua")) then
		skip_each(msg, PLAIN_LINK, "no directory symlink here: " .. tostring(err or "the link does not resolve"))
		return
	end
	out = succeeded(
		msg,
		helpers_path,
		[[
H.write_line("found=" .. H.rtp())
H.write_line("source=" .. debug.getinfo(require("kitehost.server").start, "S").source)
H.ok(true, "reached")
H.finish()]],
		link,
		{ XDG_DATA_HOME = data }
	)
	eq(printed(out, "found"), H.canon(target), msg .. ": the printed line names the target")
	eq(loaded(out), H.canon(target .. "/lua/kitehost/server.lua"), msg .. ": require loads it")
end)

-- The candidates in stubs (paths under the order directory, each a stub)
-- exist beside a copy of the checkout at <order>/mp, and the one that wins
-- is want: the printed line and the loaded source both name it. override is
-- KITEHOST_RTP and env sets LIVE_SERVER_RTP, as child() takes them.
local WINNER = { ": the child exits 0", ": the printed line names it", ": require loads it" }
local function winner(msg, order, stubs, want, override, env)
	local helpers = tree(order .. "/mp")
	for _, path in ipairs(stubs) do
		stub(order .. "/" .. path)
	end
	out = succeeded(
		msg,
		helpers,
		[[
H.rtp()
H.write_line("source=" .. debug.getinfo(require("kitehost.server").start, "S").source)
H.ok(true, "reached")
H.finish()]],
		override,
		env
	)
	eq(out:match("kitehost%.nvim: ([^\r\n]*)"), H.canon(order .. "/" .. want), msg .. ": the printed line names it")
	eq(loaded(out), H.canon(order .. "/" .. want .. "/lua/kitehost/server.lua"), msg .. ": require loads it")
end

fixture("./kitehost-rtp beats the sibling clone", WINNER, function(msg)
	winner(msg, base .. "/order", { "mp/kitehost-rtp", "kitehost.nvim" }, "mp/kitehost-rtp", "")
end)

-- A developer's clone keeps its directory name across the rename on
-- GitHub, so the sibling is tried by its name before 2.0.0 too, last.
fixture("the sibling clone beats the sibling under its name before 2.0.0", WINNER, function(msg)
	winner(msg, base .. "/order-sibling", { "kitehost.nvim", "live-server.nvim" }, "kitehost.nvim", "")
end)
fixture("the sibling under its name before 2.0.0 is found when it is the only one", WINNER, function(msg)
	winner(msg, base .. "/order-former", { "live-server.nvim" }, "live-server.nvim", "")
end)

-- The override's name before 2.0.0 is read through 2.x, after KITEHOST_RTP
-- and before every default candidate.
fixture("LIVE_SERVER_RTP is read when KITEHOST_RTP is unset", WINNER, function(msg)
	local order = base .. "/order-env"
	winner(msg, order, { "env-kh", "mp/kitehost-rtp" }, "env-kh", "", { LIVE_SERVER_RTP = order .. "/env-kh" })
end)
fixture("KITEHOST_RTP beats LIVE_SERVER_RTP", WINNER, function(msg)
	local order = base .. "/order-both"
	winner(
		msg,
		order,
		{ "new-kh", "former-kh" },
		"new-kh",
		order .. "/new-kh",
		{ LIVE_SERVER_RTP = order .. "/former-kh" }
	)
end)

-- An installed copy sits on the child's packpath beside a real kitehost at
-- the override; prepend puts the override first, where append would let
-- the installed copy answer.
fixture("the chosen kitehost beats an installed copy", CHILD_AND_ONE, function(msg)
	if not found_ok then
		skip_each(msg, CHILD_AND_ONE, "no kitehost found: " .. tostring(real_kitehost):gsub("\n.*", ""))
		return
	end
	out = succeeded(
		msg,
		helpers_path,
		[[
H.rtp()
H.write_line("source=" .. debug.getinfo(require("kitehost.server").start, "S").source)
H.ok(true, "reached")
H.finish()]],
		real_kitehost,
		{ XDG_DATA_HOME = data }
	)
	eq(loaded(out), H.canon(real_kitehost .. "/lua/kitehost/server.lua"), msg)
end)

-- The default candidates of this checkout; a contributor whose only
-- kitehost is KITEHOST_RTP has none of them, which is no failure.
local defaults = {
	H.root .. "/kitehost-rtp",
	vim.fs.dirname(H.root) .. "/kitehost.nvim",
	vim.fs.dirname(H.root) .. "/live-server.nvim",
}
local present = vim.tbl_filter(function(dir)
	return vim.fn.isdirectory(dir) == 1
end, defaults)
if #present > 0 then
	out = succeeded(
		"the default path",
		helpers_path,
		[[
H.write_line("found=" .. H.rtp())
H.write_line("source=" .. debug.getinfo(require("kitehost.server").start, "S").source)
H.ok(true, "reached")
H.finish()]],
		""
	)
	local found = printed(out, "found")
	ok(
		found ~= nil and loaded(out) == H.canon(found .. "/lua/kitehost/server.lua"),
		"the default path: require loads from the directory H.rtp() prints"
	)
else
	skip_each(
		"the default path",
		{ ": the child exits 0", ": require loads from the directory H.rtp() prints" },
		"none of " .. table.concat(defaults, ", ") .. " exists"
	)
end

H.finish()
