-- lua/markdown_preview/remote.lua
local uv = vim.uv

local M = {}

-- How long a push waits for the primary's status line.
M.timeout_ms = 2000

-- on_done(sent, cause) runs in a luv callback, where most of the API is refused.
function M.send_event(port, event_type, json_data, token, on_done)
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
	local armed, arm_err = timer:start(M.timeout_ms, 0, function()
		finish(false, ("no answer in %d ms"):format(M.timeout_ms))
	end)
	if not armed then
		return finish(false, tostring(arm_err))
	end

	local encoded = vim.uri_encode(json_data)
	local query = string.format("event=%s&data=%s", event_type, encoded)
	if token and token ~= "" then
		query = query .. "&t=" .. vim.uri_encode(token)
	end
	local req = string.format("GET /__live/inject?%s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", query)
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

return M
