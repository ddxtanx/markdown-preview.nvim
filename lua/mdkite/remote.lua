-- lua/mdkite/remote.lua
local uv = vim.uv

local M = {}

-- How long a push waits for the primary's status line.
M.timeout_ms = 2000

-- One GET of the server's inject route with params and the token; its
-- first status line decides, 2xx being sent. on_done(sent, cause) runs in a
-- luv callback, where most of the API is refused.
local function inject(port, params, token, timeout_ms, on_done)
	local tcp, timer
	local finished = false
	local function finish(sent, cause)
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
			on_done(sent, cause)
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

	local query = params
	if token and token ~= "" then
		query = (query ~= "" and (query .. "&") or "") .. "t=" .. vim.uri_encode(token)
	end
	local target = "/__live/inject" .. (query ~= "" and ("?" .. query) or "")
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
				finish(true)
			else
				-- Whatever holds the port writes this line: 64 bytes, each unprintable one marked.
				finish(false, "the primary answered " .. line:sub(1, 64):gsub("[^\32-\126]", "?"))
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
-- event: the route then broadcasts nothing, and answers 2xx only past its
-- token gate, which refuses any other token with 401.
function M.takes_token(port, token, timeout_ms, on_done)
	inject(port, "", token, timeout_ms, on_done)
end

return M
