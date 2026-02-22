local _ = require('overleaf.config')

local M = {}

M._collaborators = {} -- user_id -> { name, doc_id, row, col, color_idx }
M._ns = vim.api.nvim_create_namespace('overleaf_cursors')

-- Color palette for collaborator cursors
local COLORS = {
  { fg = '#ffffff', bg = '#e06c75' }, -- red
  { fg = '#ffffff', bg = '#61afef' }, -- blue
  { fg = '#ffffff', bg = '#98c379' }, -- green
  { fg = '#ffffff', bg = '#e5c07b' }, -- yellow
  { fg = '#ffffff', bg = '#c678dd' }, -- purple
}

local _hl_created = false
local _color_counter = 0

local function ensure_highlights()
  if _hl_created then return end
  _hl_created = true
  for i, color in ipairs(COLORS) do
    vim.api.nvim_set_hl(0, 'OverleafCursor' .. i, { fg = color.fg, bg = color.bg, bold = true })
    vim.api.nvim_set_hl(0, 'OverleafCursorName' .. i, { fg = color.bg, italic = true })
  end
end

local function assign_color()
  _color_counter = _color_counter + 1
  return ((_color_counter - 1) % #COLORS) + 1
end

--- Find bufnr for a doc_id from the overleaf state
local function find_bufnr(doc_id)
  local state = require('overleaf')._state
  local doc = state.documents[doc_id]
  if doc and doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then return doc.bufnr end
  return nil
end

--- Handle clientTracking.clientUpdated event
function M.on_client_updated(data)
  if not data or not data.id then return end

  ensure_highlights()

  local user_id = data.id
  local collab = M._collaborators[user_id]

  if not collab then
    collab = {
      name = data.name or data.email or 'User',
      color_idx = assign_color(),
    }
    M._collaborators[user_id] = collab
  end

  -- Update position
  if data.name then collab.name = data.name end
  collab.doc_id = data.doc_id
  collab.row = data.row or 0
  collab.col = data.column or 0

  -- Render cursor
  M._render_cursor(user_id, collab)
end

--- Handle clientTracking.clientDisconnected event
function M.on_client_disconnected(data)
  if not data or not data.id then return end

  local user_id = data.id
  local collab = M._collaborators[user_id]
  if not collab then return end

  -- Clear extmark
  if collab.doc_id then
    local bufnr = find_bufnr(collab.doc_id)
    if bufnr then
      vim.api.nvim_buf_clear_namespace(bufnr, M._ns, 0, -1)
      -- Re-render remaining cursors on this buffer
      for uid, c in pairs(M._collaborators) do
        if uid ~= user_id and c.doc_id == collab.doc_id then M._render_cursor(uid, c) end
      end
    end
  end

  M._collaborators[user_id] = nil
end

--- Render a single collaborator cursor as extmark
function M._render_cursor(user_id, collab)
  if not collab.doc_id then return end

  local bufnr = find_bufnr(collab.doc_id)
  if not bufnr then return end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local row = math.max(0, math.min(collab.row, line_count - 1))

  -- Clamp column to line length
  local line_text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
  local col = math.max(0, math.min(collab.col, #line_text))

  local hl_cursor = 'OverleafCursor' .. collab.color_idx
  local hl_name = 'OverleafCursorName' .. collab.color_idx

  local mark_id = M._get_mark_id(user_id)
  pcall(vim.api.nvim_buf_del_extmark, bufnr, M._ns, mark_id)

  -- Place extmark at exact row:col with a highlighted cursor character
  local end_col = math.min(col + 1, #line_text)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, M._ns, row, col, {
    id = mark_id,
    end_col = end_col,
    hl_group = hl_cursor,
    virt_text = { { ' ' .. collab.name .. ' ', hl_name } },
    virt_text_pos = 'eol',
    priority = 100,
  })
end

--- Generate a stable numeric mark ID from user_id string
function M._get_mark_id(user_id)
  local hash = 0
  for i = 1, #user_id do
    hash = (hash * 31 + string.byte(user_id, i)) % 2147483647
  end
  return math.max(1, hash)
end

--- Clear all collaborator cursors
function M.clear_all()
  for _, doc in pairs(require('overleaf')._state.documents) do
    if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
      vim.api.nvim_buf_clear_namespace(doc.bufnr, M._ns, 0, -1)
    end
  end
  M._collaborators = {}
end

return M
