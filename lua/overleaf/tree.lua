local project = require('overleaf.project')
local config = require('overleaf.config')

local M = {}

M._bufnr = nil
M._tree_winnr = nil
M._editor_winnr = nil
M._width = 35

--- Toggle the file tree sidebar
function M.toggle()
  -- Tree window visible?
  if M._tree_winnr and vim.api.nvim_win_is_valid(M._tree_winnr) then
    local cur_win = vim.api.nvim_get_current_win()
    if cur_win == M._tree_winnr then
      if M._editor_winnr and vim.api.nvim_win_is_valid(M._editor_winnr) then
        -- Editor exists: close tree, focus editor
        vim.api.nvim_win_close(M._tree_winnr, true)
        M._tree_winnr = nil
        vim.api.nvim_set_current_win(M._editor_winnr)
      else
        -- Tree is the only window: quit
        vim.cmd('quit')
        M._tree_winnr = nil
      end
    else
      -- Not in tree: focus tree
      vim.api.nvim_set_current_win(M._tree_winnr)
    end
    return
  end

  -- Tree not visible: open it
  M._open()
end

function M._open()
  M._ensure_buffer()

  -- If there's an editor window, open tree as left sidebar
  if M._editor_winnr and vim.api.nvim_win_is_valid(M._editor_winnr) then
    vim.cmd('topleft ' .. M._width .. 'vsplit')
    M._tree_winnr = vim.api.nvim_get_current_win()
    vim.wo[M._tree_winnr].winfixwidth = true
  else
    -- No editor window: show tree in current window (full pane)
    M._tree_winnr = vim.api.nvim_get_current_win()
  end

  vim.api.nvim_win_set_buf(M._tree_winnr, M._bufnr)

  -- Window options
  vim.wo[M._tree_winnr].number = false
  vim.wo[M._tree_winnr].relativenumber = false
  vim.wo[M._tree_winnr].signcolumn = 'no'
  vim.wo[M._tree_winnr].cursorline = true

  M.refresh()
end

function M._ensure_buffer()
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then return end

  M._bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[M._bufnr].buftype = 'nofile'
  vim.bo[M._bufnr].swapfile = false
  vim.bo[M._bufnr].filetype = 'overleaf-tree'
  vim.api.nvim_buf_set_name(M._bufnr, 'overleaf://tree')

  -- Keymaps
  vim.keymap.set('n', '<CR>', function() M._on_enter() end, { buffer = M._bufnr, desc = 'Open' })
  vim.keymap.set('n', 'q', function() M.toggle() end, { buffer = M._bufnr, desc = 'Close tree' })
  vim.keymap.set('n', 'R', function() M.refresh() end, { buffer = M._bufnr, desc = 'Refresh' })
  vim.keymap.set('n', 'a', function() M._create_doc() end, { buffer = M._bufnr, desc = 'New doc' })
  vim.keymap.set('n', 'A', function() M._create_folder() end, { buffer = M._bufnr, desc = 'New folder' })
  vim.keymap.set('n', 'd', function() M._delete_entry() end, { buffer = M._bufnr, desc = 'Delete' })
  vim.keymap.set('n', 'r', function() M._rename_entry() end, { buffer = M._bufnr, desc = 'Rename' })
  vim.keymap.set('n', 'u', function() M._upload_file() end, { buffer = M._bufnr, desc = 'Upload file' })
end

--- Refresh the tree display
function M.refresh()
  if not M._bufnr or not vim.api.nvim_buf_is_valid(M._bufnr) then
    return
  end

  local tree = project._project_tree
  local lines = {}
  local ns = vim.api.nvim_create_namespace('overleaf_tree_hl')

  for _, entry in ipairs(tree) do
    local indent = string.rep('  ', entry.depth or 0)
    local icon, line
    if entry.type == 'folder' then
      icon = '  '
      line = indent .. icon .. entry.name .. '/'
    elseif entry.type == 'doc' then
      icon = '  '
      line = indent .. icon .. entry.name
    else -- file
      icon = '  '
      line = indent .. icon .. entry.name
    end
    table.insert(lines, line)
  end

  if #lines == 0 then
    lines = { '  (no files)' }
  end

  vim.bo[M._bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M._bufnr, 0, -1, false, lines)
  vim.bo[M._bufnr].modifiable = false

  -- Apply highlights
  vim.api.nvim_buf_clear_namespace(M._bufnr, ns, 0, -1)
  for i, entry in ipairs(tree) do
    if entry.type == 'folder' then
      vim.api.nvim_buf_add_highlight(M._bufnr, ns, 'Directory', i - 1, 0, -1)
    end
  end
end

--- Handle <CR> on a tree entry
function M._on_enter()
  local line_idx = vim.api.nvim_win_get_cursor(0)[1]
  local tree = project._project_tree

  if line_idx > #tree then return end

  local entry = tree[line_idx]
  if not entry then return end

  if entry.type == 'doc' then
    -- Find or create editor window to the right
    if not M._editor_winnr or not vim.api.nvim_win_is_valid(M._editor_winnr) then
      vim.cmd('rightbelow vsplit')
      M._editor_winnr = vim.api.nvim_get_current_win()
      -- Shrink tree to sidebar width
      if M._tree_winnr and vim.api.nvim_win_is_valid(M._tree_winnr) then
        vim.api.nvim_win_set_width(M._tree_winnr, M._width)
        vim.wo[M._tree_winnr].winfixwidth = true
      end
    else
      vim.api.nvim_set_current_win(M._editor_winnr)
    end
    -- Current window is now the editor — open_document sets buffer here
    require('overleaf').open_document(entry.id, entry.path)
  elseif entry.type == 'file' then
    config.log('info', 'Binary files cannot be opened: %s', entry.name)
  end
  -- No-op for folders
end

--- Get the parent folder ID of the entry under cursor
function M._get_parent_folder_id()
  local line_idx = vim.api.nvim_win_get_cursor(0)[1]
  local tree = project._project_tree
  if line_idx > #tree then return nil end
  local entry = tree[line_idx]
  if not entry then return nil end
  if entry.type == 'folder' then return entry.id end
  -- For files/docs, find parent folder by path
  local parent_path = entry.path:match('^(.*/)') or ''
  for _, e in ipairs(tree) do
    if e.type == 'folder' and e.path == parent_path then
      return e.id
    end
  end
  return nil -- root folder
end

function M._create_doc()
  local parent = M._get_parent_folder_id()
  require('overleaf').create_doc(nil, parent)
end

function M._create_folder()
  local parent = M._get_parent_folder_id()
  require('overleaf').create_folder(nil, parent)
end

function M._delete_entry()
  local line_idx = vim.api.nvim_win_get_cursor(0)[1]
  local tree = project._project_tree
  if line_idx > #tree then return end
  local entry = tree[line_idx]
  if not entry then return end

  vim.ui.input({ prompt = 'Delete "' .. entry.path .. '"? (y/N): ' }, function(answer)
    if answer ~= 'y' and answer ~= 'Y' then return end
    local ol = require('overleaf')
    local bridge = require('overleaf.bridge')
    bridge.request('deleteEntity', {
      cookie = require('overleaf.config').get().cookie,
      csrfToken = ol._state.csrf_token,
      projectId = ol._state.project_id,
      entityId = entry.id,
      entityType = entry.type,
    }, function(err, _)
      if err then
        config.log('error', 'Delete failed: %s', err.message)
        return
      end
      config.log('info', 'Deleted: %s', entry.path)
      vim.schedule(function()
        project.remove_entry(entry.id)
        M.refresh()
      end)
    end)
  end)
end

function M._upload_file()
  local parent = M._get_parent_folder_id()
  require('overleaf').upload_file(nil, parent)
end

function M._rename_entry()
  local line_idx = vim.api.nvim_win_get_cursor(0)[1]
  local tree = project._project_tree
  if line_idx > #tree then return end
  local entry = tree[line_idx]
  if not entry then return end

  vim.ui.input({ prompt = 'Rename "' .. entry.name .. '" to: ', default = entry.name }, function(new_name)
    if not new_name or new_name == '' or new_name == entry.name then return end
    local ol = require('overleaf')
    local bridge = require('overleaf.bridge')
    bridge.request('renameEntity', {
      cookie = require('overleaf.config').get().cookie,
      csrfToken = ol._state.csrf_token,
      projectId = ol._state.project_id,
      entityId = entry.id,
      entityType = entry.type,
      newName = new_name,
    }, function(err, _)
      if err then
        config.log('error', 'Rename failed: %s', err.message)
        return
      end
      vim.schedule(function()
        local updated = project.rename_entry(entry.id, new_name)
        if updated then
          -- Update open buffer name if it's a doc
          if entry.type == 'doc' then
            local doc = ol._state.documents[entry.id]
            if doc and doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
              doc.path = updated.path
              vim.api.nvim_buf_set_name(doc.bufnr, 'overleaf://' .. updated.path)
            end
          end
          config.log('info', 'Renamed to: %s', updated.path)
        end
        M.refresh()
      end)
    end)
  end)
end

return M
