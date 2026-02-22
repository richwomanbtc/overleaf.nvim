local config = require('overleaf.config')

local M = {}

M._job_id = nil
M._request_id = 0
M._pending = {} -- id -> {callback, timer}
M._event_handlers = {} -- event_name -> handler[]
M._buffer = ''
M._started = false
M._on_unexpected_exit = nil -- callback for auto-reconnect

function M.start(callback)
  if M._job_id then
    if callback then callback(nil) end
    return
  end

  local script = config.bridge_script()
  local node = config.get().node_path

  -- Pass base_url to bridge as OVERLEAF_URL environment variable
  local env = nil
  local base_url = config.get().base_url
  if base_url and base_url ~= 'https://www.overleaf.com' then
    env = { OVERLEAF_URL = base_url }
  end

  M._job_id = vim.fn.jobstart({ node, script }, {
    env = env,
    on_stdout = function(_, data, _)
      M._on_stdout(data)
    end,
    on_stderr = function(_, data, _)
      for _, line in ipairs(data) do
        if line ~= '' then
          config.log('debug', 'bridge: %s', line)
        end
      end
    end,
    on_exit = function(_, code, _)
      config.log('warn', 'Bridge exited with code %d', code)
      local was_started = M._started
      M._job_id = nil
      M._started = false
      -- Notify pending requests of failure
      for _, pending in pairs(M._pending) do
        if pending.timer then
          vim.fn.timer_stop(pending.timer)
        end
        if pending.callback then
          vim.schedule(function()
            pending.callback({ code = 'BRIDGE_DIED', message = 'Bridge process exited' }, nil)
          end)
        end
      end
      M._pending = {}
      -- Trigger auto-restart if bridge died unexpectedly
      if was_started and M._on_unexpected_exit then
        vim.schedule(function()
          M._on_unexpected_exit(code)
        end)
      end
    end,
    stdout_buffered = false,
    stderr_buffered = false,
  })

  if M._job_id <= 0 then
    config.log('error', 'Failed to start bridge process')
    M._job_id = nil
    if callback then callback({ code = 'START_FAILED', message = 'Failed to start Node.js bridge' }) end
    return
  end

  M._started = true
  config.log('info', 'Bridge started (job_id=%d)', M._job_id)

  -- Send a ping to verify bridge is ready
  M.request('ping', {}, function(err, _result)
    if callback then callback(err) end
  end)
end

function M.stop()
  if M._job_id then
    M.request('disconnect', {}, function() end)
    vim.defer_fn(function()
      if M._job_id then
        vim.fn.jobstop(M._job_id)
        M._job_id = nil
        M._started = false
      end
    end, 500)
  end
end

function M.is_running()
  return M._job_id ~= nil and M._started
end

function M.request(method, params, callback)
  if not M._job_id then
    if callback then
      callback({ code = 'NOT_STARTED', message = 'Bridge not started' }, nil)
    end
    return
  end

  M._request_id = M._request_id + 1
  local id = M._request_id

  local msg = vim.json.encode({
    id = id,
    method = method,
    params = params or {},
  })

  -- Set timeout (30s)
  local timer = vim.fn.timer_start(30000, function()
    local pending = M._pending[id]
    M._pending[id] = nil
    if pending and pending.callback then
      vim.schedule(function()
        pending.callback({ code = 'TIMEOUT', message = method .. ' timed out' }, nil)
      end)
    end
  end)

  M._pending[id] = { callback = callback, timer = timer }

  vim.fn.chansend(M._job_id, msg .. '\n')
end

function M.on_event(event_name, handler)
  if not M._event_handlers[event_name] then
    M._event_handlers[event_name] = {}
  end
  table.insert(M._event_handlers[event_name], handler)
end

function M.off_event(event_name, handler)
  local handlers = M._event_handlers[event_name]
  if handlers then
    for i, h in ipairs(handlers) do
      if h == handler then
        table.remove(handlers, i)
        return
      end
    end
  end
end

function M._on_stdout(data)
  -- data is a list of strings, first and last may be partial lines
  for i, chunk in ipairs(data) do
    if i == 1 then
      M._buffer = M._buffer .. chunk
    else
      -- Previous buffer forms a complete line
      local line = M._buffer
      M._buffer = chunk
      if line ~= '' then
        M._handle_message(line)
      end
    end
  end
end

function M._handle_message(line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok then
    config.log('warn', 'Failed to parse bridge message: %s', line)
    return
  end

  -- Response to a request
  if msg.id then
    local pending = M._pending[msg.id]
    M._pending[msg.id] = nil
    if pending then
      if pending.timer then
        vim.fn.timer_stop(pending.timer)
      end
      if pending.callback then
        vim.schedule(function()
          pending.callback(msg.error, msg.result)
        end)
      end
    end
    return
  end

  -- Server-push event
  if msg.event then
    local handlers = M._event_handlers[msg.event]
    if handlers then
      vim.schedule(function()
        for _, handler in ipairs(handlers) do
          handler(msg.data)
        end
      end)
    end
    return
  end
end

return M
