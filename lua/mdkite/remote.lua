-- lua/mdkite/remote.lua
local uv = vim.uv

local M = {}

-- How long a push waits for the primary's status line.
M.timeout_ms = 2000

-- One GET of the server's inject route with params and the token; its
-- first status line decides, 2xx being sent. on_done(sent, cause, status)
-- runs in a luv callback, where most of the API is refused; status is the
-- answer's three digits, nil when none came.
local function inject(port, params, token, timeout_ms, on_done)
	local tcp, timer
	local finished = false
	local function finish(sent, cause, status)
		if finished then
			return
		end
		finished = true
		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
		if tcp and not tcp:is_closing() then
			tcp:close()
		end
		if on_done then
			on_done(sent, cause, status)
		end
	end

	local tcp_err, timer_err
	tcp, tcp_err = uv.new_tcp()
	if not tcp then
		return finish(false, tostring(tcp_err))
	end
	timer, timer_err = uv.new_timer()
	if not timer then
		return finish(false, tostring(timer_err))
	end
	local armed, arm_err = timer:start(timeout_ms, 0, function()
		finish(false, ("no answer in %d ms"):format(timeout_ms))
	end)
	if not armed then
		return finish(false, tostring(arm_err))
	end

	-- A lock's token is read from a file: one that is no string would raise
	-- in the encoding, and the default set leaves & and = as they are, so a
	-- token carrying &event=reload sent the holder's pages an event.
	local query = params
	if type(token) == "string" and token ~= "" then
		query = (query ~= "" and (query .. "&") or "") .. "t=" .. vim.uri_encode(token, "rfc2396")
	end
	-- The ? stays with no query: the server's releases 1.2.2 and 1.3.0 route
	-- the bare path to a file and answer 404, so an older preview there read
	-- as no holder; 1.5.0 and later answer both alike (measured).
	local target = "/__live/inject?" .. query
	local req = string.format("GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", target)
	local connecting, connect_err = tcp:connect("127.0.0.1", port, function(err)
		if err then
			return finish(false, ("the primary on port %d is gone (%s)"):format(port, tostring(err)))
		end
		local head = ""
		local reading, read_err = tcp:read_start(function(chunk_err, chunk)
			if chunk_err then
				return finish(false, tostring(chunk_err))
			end
			if not chunk then
				return finish(false, "the primary closed the connection without a status line")
			end
			head = head .. chunk
			local line = head:match("^([^\r\n]*)\r\n")
			if not line then
				if #head > 1024 then
					finish(false, "the primary's answer has no status line")
				end
				return
			end
			local status = line:match("^HTTP/%d%.%d (%d%d%d)")
			if status and status:sub(1, 1) == "2" then
				finish(true, nil, status)
			else
				-- Whatever holds the port writes this line: 64 bytes, each unprintable one marked.
				finish(false, "the primary answered " .. line:sub(1, 64):gsub("[^\32-\126]", "?"), status)
			end
		end)
		if not reading then
			return finish(false, tostring(read_err))
		end
		local writing, write_err = tcp:write(req, function(written_err)
			if written_err then
				finish(false, tostring(written_err))
			end
		end)
		if not writing then
			finish(false, tostring(write_err))
		end
	end)
	if not connecting then
		finish(false, tostring(connect_err))
	end
end

function M.send_event(port, event_type, json_data, token, on_done)
	local params = string.format("event=%s&data=%s", event_type, vim.uri_encode(json_data))
	inject(port, params, token, M.timeout_ms, on_done)
end

-- Asks whether the server on port takes token, as a push asks but with no
-- event: the route then broadcasts nothing and answers 2xx only past its
-- token gate. A server with a token refuses any other, or none, with 401; a
-- server without one takes any.
function M.takes_token(port, token, timeout_ms, on_done)
	inject(port, "", token, timeout_ms, on_done)
end

return M
