local bridge = require('overleaf.bridge')
local config = require('overleaf.config')
local project = require('overleaf.project')

local M = {}

--- Search all project documents for a Lua pattern
--- Results are shown in quickfix list
function M.grep(pattern, state)
  if not pattern or pattern == '' then return end

  local docs = {}
  for _, entry in ipairs(project._project_tree) do
    if entry.type == 'doc' then
      table.insert(docs, entry)
    end
  end

  if #docs == 0 then
    config.log('info', 'No documents to search')
    return
  end

  local results = {}
  local total = #docs
  local processed = 0

  config.log('info', 'Searching %d documents...', total)

  local function finish()
    vim.schedule(function()
      if #results == 0 then
        config.log('info', 'No matches found for: %s', pattern)
        return
      end

      -- Build quickfix entries
      local qf_items = {}
      for _, r in ipairs(results) do
        table.insert(qf_items, {
          filename = 'overleaf://' .. r.path,
          lnum = r.lnum,
          col = r.col,
          text = r.text,
        })
      end

      vim.fn.setqflist({}, 'r', {
        title = 'Overleaf Search: ' .. pattern,
        items = qf_items,
      })
      vim.cmd('copen')
      -- Map q to close quickfix window
      local qf_buf = vim.api.nvim_get_current_buf()
      vim.keymap.set('n', 'q', '<cmd>cclose<CR>', { buffer = qf_buf, nowait = true })
      config.log('info', 'Found %d matches in %d documents', #results, total)
    end)
  end

  local function search_content(doc_path, content)
    local lines = vim.split(content, '\n', { plain = true })
    for lnum, line in ipairs(lines) do
      local col = line:find(pattern)
      if col then
        table.insert(results, {
          path = doc_path,
          lnum = lnum,
          col = col,
          text = vim.trim(line),
        })
      end
    end
  end

  local function process_next(idx)
    if idx > total then
      finish()
      return
    end

    local doc_entry = docs[idx]
    processed = processed + 1

    -- Check if document is already open (has content in memory)
    local open_doc = state and state.documents[doc_entry.id]
    if open_doc and open_doc.content then
      search_content(doc_entry.path, open_doc.content)
      process_next(idx + 1)
      return
    end

    -- Join doc temporarily to search
    bridge.request('joinDoc', { docId = doc_entry.id }, function(err, result)
      if not err and result and result.lines then
        local content = table.concat(result.lines, '\n')
        search_content(doc_entry.path, content)
      end

      -- Leave the doc after searching
      bridge.request('leaveDoc', { docId = doc_entry.id }, function()
        process_next(idx + 1)
      end)
    end)
  end

  process_next(1)
end

return M
