local bridge = require('overleaf.bridge')
local config = require('overleaf.config')

local M = {}

M._threads = {}  -- threadId -> { id, messages, resolved, resolved_by }
M._doc_comments = {} -- docId -> { { threadId, offset, length, content } }
M._ns = vim.api.nvim_create_namespace('overleaf_comments')

-- Highlight groups for comment ranges
vim.api.nvim_set_hl(0, 'OverleafComment', { underline = true, bg = '#3a3520', sp = '#f0c674' })
vim.api.nvim_set_hl(0, 'OverleafCommentResolved', { underline = true, bg = '#2a2a2a', sp = '#666666' })
vim.api.nvim_set_hl(0, 'OverleafCommentSign', { fg = '#f0c674' })

--- Load all threads from the Overleaf API
function M.load_threads(project_id, callback)
  bridge.request('getThreads', {
    cookie = config.get().cookie,
    projectId = project_id,
  }, function(err, result)
    if err then
      config.log('error', 'Failed to load threads: %s', err.message)
      if callback then callback(err) end
      return
    end

    -- result is a table: threadId -> thread data
    M._threads = {}
    if type(result) == 'table' then
      for thread_id, thread in pairs(result) do
        M._threads[thread_id] = {
          id = thread_id,
          messages = thread.messages or {},
          resolved = thread.resolved ~= nil and thread.resolved ~= false,
          resolved_by = thread.resolved_by_user,
        }
      end
    end

    config.log('info', 'Loaded %d comment threads', vim.tbl_count(M._threads))
    if callback then callback(nil) end
  end)
end

--- Parse comment ranges from joinDoc ranges data
--- Overleaf ranges format: { comments: [{ id, op: { c, p, t } }], ... }
function M.parse_ranges(doc_id, ranges)
  M._doc_comments[doc_id] = {}

  if not ranges then
    config.log('debug', 'No ranges for doc %s', doc_id)
    return
  end

  local comments = ranges.comments
  if not comments then
    config.log('debug', 'No comments in ranges for doc %s (keys: %s)',
      doc_id, vim.inspect(vim.tbl_keys(ranges)))
    return
  end

  config.log('debug', 'Parsing %d comment ranges for doc %s', #comments, doc_id)

  for _, comment in ipairs(comments) do
    local op = comment.op
    if op and op.t then
      table.insert(M._doc_comments[doc_id], {
        threadId = op.t,
        offset = op.p or 0,    -- character offset in document
        length = op.c and #op.c or 0,
        content = op.c or '',
      })
      config.log('debug', 'Comment: thread=%s offset=%d len=%d text="%s"',
        op.t, op.p or 0, op.c and #op.c or 0, (op.c or ''):sub(1, 30))
    end
  end
end

--- Convert a character offset to line/col in a buffer
local function offset_to_pos(content, offset)
  local line = 1
  local col = 0
  local pos = 0
  for i = 1, #content do
    if pos >= offset then
      return line, col
    end
    if content:sub(i, i) == '\n' then
      line = line + 1
      col = 0
    else
      col = col + 1
    end
    pos = pos + 1
  end
  return line, col
end

--- Render comment markers on a buffer using extmarks
function M.render(bufnr, doc_id, content)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  vim.api.nvim_buf_clear_namespace(bufnr, M._ns, 0, -1)

  local comments = M._doc_comments[doc_id]
  if not comments or #comments == 0 then
    config.log('debug', 'render: no comments for doc %s', doc_id)
    return
  end

  config.log('debug', 'render: %d comments for doc %s', #comments, doc_id)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- First pass: collect labels per start line, and highlight ranges
  local line_labels = {} -- start_line -> { label1, label2, ... }

  for _, c in ipairs(comments) do
    local thread = M._threads[c.threadId]
    local resolved = thread and thread.resolved or false
    if not resolved then
      local start_line, start_col = offset_to_pos(content, c.offset)
      local end_line, end_col = offset_to_pos(content, c.offset + c.length)

      if start_line > line_count then start_line = line_count end
      if end_line > line_count then end_line = line_count end

      -- Build label
      local label
      if thread and thread.messages and #thread.messages > 0 then
        local msg = thread.messages[1]
        local user = msg.user and (msg.user.first_name or msg.user.email or '?') or '?'
        local text = msg.content or ''
        if #text > 30 then text = text:sub(1, 30) .. '...' end
        label = user .. ': ' .. text
      else
        label = '[comment]'
      end

      -- Collect labels per line
      if not line_labels[start_line] then
        line_labels[start_line] = {}
      end
      table.insert(line_labels[start_line], label)

      -- Highlight the range (each comment gets its own highlight)
      pcall(function()
        vim.api.nvim_buf_set_extmark(bufnr, M._ns, start_line - 1, start_col, {
          end_row = end_line - 1,
          end_col = end_col,
          hl_group = 'OverleafComment',
        })
      end)
    end
  end

  -- Second pass: add one virtual text + sign per line (combining labels)
  for line, labels in pairs(line_labels) do
    local combined = table.concat(labels, ' | ')
    pcall(function()
      vim.api.nvim_buf_set_extmark(bufnr, M._ns, line - 1, 0, {
        sign_text = '',
        sign_hl_group = 'OverleafCommentSign',
        virt_text = { { '  ' .. combined, 'Comment' } },
        virt_text_pos = 'eol',
      })
    end)
  end
end

--- Get comment thread at cursor position
function M.get_thread_at_cursor(doc_id, _content)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]
  local cursor_col = cursor[2]

  local comments = M._doc_comments[doc_id]
  if not comments then return nil end

  -- Convert cursor position to character offset
  local lines = vim.api.nvim_buf_get_lines(0, 0, cursor_line, false)
  local offset = 0
  for i = 1, #lines - 1 do
    offset = offset + #lines[i] + 1 -- +1 for newline
  end
  offset = offset + cursor_col

  for _, c in ipairs(comments) do
    if offset >= c.offset and offset <= c.offset + c.length then
      local thread = M._threads[c.threadId]
      if thread then
        return thread, c
      end
    end
  end
  return nil
end

--- Show a comment thread in a floating window
function M.show_thread(thread)
  if not thread then return end

  local lines = {}
  local resolved_str = thread.resolved and ' [RESOLVED]' or ''
  table.insert(lines, 'Comment Thread' .. resolved_str)
  table.insert(lines, string.rep('-', 40))

  for _, msg in ipairs(thread.messages or {}) do
    local user = msg.user and (msg.user.first_name or msg.user.email or '?') or '?'
    local ts = ''
    if msg.timestamp then
      ts = ' (' .. os.date('%m/%d %H:%M', msg.timestamp / 1000) .. ')'
    end
    table.insert(lines, user .. ts .. ':')
    -- Wrap long lines
    for _, line in ipairs(vim.split(msg.content or '', '\n', { plain = true })) do
      table.insert(lines, '  ' .. line)
    end
    table.insert(lines, '')
  end

  if #lines > 2 and lines[#lines] == '' then
    table.remove(lines)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = 'nofile'

  local width = 50
  local height = math.min(#lines, 15)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' Comments ',
    title_pos = 'center',
  })

  -- Close on q, Esc, or when leaving the window
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set('n', 'q', close, { buffer = buf })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf })
  vim.api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
    buffer = buf,
    once = true,
    callback = close,
  })
end

--- Show all comments in quickfix
function M.list_all(_project_id)
  local qf_items = {}

  for doc_id, comments in pairs(M._doc_comments) do
    -- Find doc path
    local doc_path = doc_id
    for _, entry in ipairs(require('overleaf.project')._project_tree) do
      if entry.id == doc_id then
        doc_path = entry.path
        break
      end
    end

    for _, c in ipairs(comments) do
      local thread = M._threads[c.threadId]
      if thread and not thread.resolved then
        local msg = ''
        if thread.messages and #thread.messages > 0 then
          msg = (thread.messages[1].content or ''):gsub('\n', ' ')
        end
        table.insert(qf_items, {
          filename = 'overleaf://' .. doc_path,
          lnum = 1, -- approximate, would need content to compute
          text = msg,
        })
      end
    end
  end

  if #qf_items == 0 then
    config.log('info', 'No open comments')
    return
  end

  vim.fn.setqflist({}, 'r', {
    title = 'Overleaf Comments',
    items = qf_items,
  })
  vim.cmd('copen')
  local qf_buf = vim.api.nvim_get_current_buf()
  vim.keymap.set('n', 'q', '<cmd>cclose<CR>', { buffer = qf_buf, nowait = true })
end

--- Handle socket events
function M.on_new_comment(data)
  if not data or not data.threadId then return end
  local thread = M._threads[data.threadId]
  if thread and data.comment then
    table.insert(thread.messages, data.comment)
  end
end

function M.on_resolve_thread(data)
  if not data or not data.threadId then return end
  local thread = M._threads[data.threadId]
  if thread then
    thread.resolved = true
    thread.resolved_by = data.user
  end
end

function M.on_reopen_thread(data)
  if not data or not data.threadId then return end
  local thread = M._threads[data.threadId]
  if thread then
    thread.resolved = false
    thread.resolved_by = nil
  end
end

function M.on_delete_thread(data)
  if not data or not data.threadId then return end
  M._threads[data.threadId] = nil
  -- Remove from doc_comments
  for _, comments in pairs(M._doc_comments) do
    for i = #comments, 1, -1 do
      if comments[i].threadId == data.threadId then
        table.remove(comments, i)
      end
    end
  end
end

function M.clear_all()
  M._threads = {}
  M._doc_comments = {}
end

return M
