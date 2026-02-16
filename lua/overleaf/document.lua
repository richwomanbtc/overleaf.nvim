local bridge = require('overleaf.bridge')
local ot = require('overleaf.ot')
local config = require('overleaf.config')

local Document = {}
Document.__index = Document

function Document.new(doc_id, path)
  local self = setmetatable({}, Document)
  self.doc_id = doc_id
  self.path = path
  self.bufnr = nil
  self.version = nil
  self.content = nil         -- local content (includes unacked changes)
  self.server_content = nil  -- content at doc.version (server's view)
  self.joined = false
  self.inflight_op = nil     -- op sent, awaiting ACK
  self.pending_ops = nil     -- local ops not yet sent
  self.applying_remote = false
  self._flush_timer = nil
  return self
end

function Document:join(callback)
  bridge.request('joinDoc', { docId = self.doc_id }, function(err, result)
    if err then
      config.log('error', 'Failed to join doc %s: %s', self.path, err.message)
      if callback then callback(err) end
      return
    end

    local content = table.concat(result.lines, '\n')
    self.version = result.version
    self.content = content
    self.server_content = content
    self.joined = true
    self.ranges = result.ranges

    config.log('info', 'Joined doc: %s (v%d, %d lines)', self.path, self.version, #result.lines)

    if callback then callback(nil, result.lines, result.ranges) end
  end)
end

function Document:leave(callback)
  if not self.joined then
    if callback then callback(nil) end
    return
  end

  if self._flush_timer then
    vim.fn.timer_stop(self._flush_timer)
    self._flush_timer = nil
  end

  bridge.request('leaveDoc', { docId = self.doc_id }, function(err, _)
    self.joined = false
    self.inflight_op = nil
    self.pending_ops = nil
    if callback then callback(err) end
  end)
end

function Document:submit_op(ops)
  if not self.joined or self._rejoining then return end

  if self.pending_ops then
    self.pending_ops = ot.compose(self.pending_ops, ops)
  else
    self.pending_ops = ops
  end

  self:_schedule_flush()
end

function Document:_schedule_flush()
  if self._flush_timer then
    vim.fn.timer_stop(self._flush_timer)
  end
  self._flush_timer = vim.fn.timer_start(100, function()
    self._flush_timer = nil
    if self.joined and not self._rejoining then
      self:flush()
    end
  end)
end

function Document:flush()
  if not self.joined or self._rejoining then return end
  if self.inflight_op or not self.pending_ops then
    return
  end

  self.inflight_op = self.pending_ops
  self.pending_ops = nil

  bridge.request('applyOtUpdate', {
    docId = self.doc_id,
    op = self.inflight_op,
    v = self.version,
    content = self.server_content,
  }, function(err, _)
    if err then
      config.log('debug', 'OT update failed: %s', err.message)
      self.inflight_op = nil
      self.pending_ops = nil
      return
    end
    self:_on_ack()
  end)
end

function Document:_on_ack()
  -- Update server_content with the acked operation
  self.server_content = ot.apply(self.server_content, self.inflight_op)
  self.version = self.version + 1
  self.inflight_op = nil

  config.log('debug', 'ACK received for %s, now v%d', self.path, self.version)

  -- Flush next pending if any
  if self.pending_ops then
    self:flush()
  end
end

--- Rejoin document to resync state (e.g., after version mismatch or restore)
---@param attempt number internal retry counter
function Document:rejoin(attempt)
  attempt = attempt or 1
  if self._rejoining and attempt == 1 then return end
  self._rejoining = true
  self.joined = false
  self.inflight_op = nil
  self.pending_ops = nil

  -- Delays: 3s, 8s, 15s, 25s, 40s (total ~90s)
  local delays = { 3000, 8000, 15000, 25000, 40000 }
  local delay = delays[attempt] or 40000

  vim.defer_fn(function()
    if not require('overleaf')._state.connected then
      self._rejoining = false
      return
    end

    bridge.request('joinDoc', { docId = self.doc_id }, function(err, result)
      if err then
        config.log('warn', 'joinDoc failed for %s (attempt %d): %s',
          self.path, attempt, vim.inspect(err))
        if attempt < 5 then
          self:rejoin(attempt + 1)
        else
          config.log('info', 'Could not rejoin %s — use :Overleaf disconnect then :Overleaf to reconnect', self.path)
          self._rejoining = false
        end
        return
      end

      self._rejoining = false
      local content = table.concat(result.lines, '\n')
      self.version = result.version
      self.content = content
      self.server_content = content
      self.joined = true
      self.ranges = result.ranges

      config.log('info', 'Rejoined doc %s (v%d)', self.path, self.version)

      if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
        vim.schedule(function()
          self.applying_remote = true
          vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, result.lines)
          vim.bo[self.bufnr].modified = false
          self.applying_remote = false
        end)
      end
    end)
  end, delay)
end

--- Handle a remote OT update from another user
---@param update table {doc, op, v, meta}
---@param apply_to_buffer function(ops) callback to apply transformed ops to neovim buffer
function Document:on_remote_op(update, apply_to_buffer)
  if not self.joined then return end

  -- Version check — on mismatch, rejoin to resync
  if update.v ~= self.version then
    config.log('debug', 'Version mismatch: expected %d, got %d for %s',
      self.version, update.v, self.path)
    if require('overleaf')._state.connected then
      self:rejoin()
    end
    return
  end

  local remote_ops = update.op or {}
  if #remote_ops == 0 then
    return
  end

  -- Wrap entire OT processing in pcall — rejoin on any failure
  local ok, err = pcall(function()
    self.server_content = ot.apply(self.server_content, remote_ops)

    local ops_to_apply = remote_ops

    if self.inflight_op then
      ops_to_apply = ot.transform_ops(remote_ops, self.inflight_op, 'right')
      self.inflight_op = ot.transform_ops(self.inflight_op, remote_ops, 'left')
    end

    if self.pending_ops then
      local ops_for_pending = ops_to_apply
      ops_to_apply = ot.transform_ops(ops_to_apply, self.pending_ops, 'right')
      self.pending_ops = ot.transform_ops(self.pending_ops, ops_for_pending, 'left')
    end

    self.version = self.version + 1
    self.content = ot.apply(self.content, ops_to_apply)

    if apply_to_buffer then
      apply_to_buffer(ops_to_apply)
    end
  end)

  if not ok then
    config.log('error', 'Remote op failed for %s: %s — rejoining', self.path, err)
    self:rejoin()
  end
end

return Document
