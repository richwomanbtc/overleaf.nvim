-- OT (Operational Transform) engine for Overleaf protocol
-- Operations: {p = position (0-based byte offset), i = "insert text"} / {p, d = "delete text"}

local M = {}

--- Apply a list of operations to a content string
--- Operations must be applied from last to first (reverse order) to avoid position shifts
---@param content string
---@param ops table[] list of {p, i?, d?}
---@return string new content
function M.apply(content, ops)
  -- Apply ops in order - caller is responsible for ordering
  for _, op in ipairs(ops) do
    if op.d then
      local p = op.p -- 0-based
      local d = op.d
      local before = content:sub(1, p)
      local after = content:sub(p + #d + 1)
      content = before .. after
    end
    if op.i then
      local p = op.p -- 0-based
      local before = content:sub(1, p)
      local after = content:sub(p + 1)
      content = before .. op.i .. after
    end
  end
  return content
end

--- Transform component c1 against component c2
--- side: 'left' means c1 wins ties, 'right' means c2 wins ties
---@param c1 table single op component {p, i?, d?}
---@param c2 table single op component {p, i?, d?}
---@param side string 'left' or 'right'
---@return table[] list of transformed components (usually 1, sometimes 2 for split deletes)
function M.transform_component(c1, c2, side)
  -- c1 is insert
  if c1.i then
    if c2.i then
      -- Insert vs Insert
      if c1.p < c2.p or (c1.p == c2.p and side == 'left') then
        return { { p = c1.p, i = c1.i } }
      else
        return { { p = c1.p + #c2.i, i = c1.i } }
      end
    elseif c2.d then
      -- Insert vs Delete
      if c1.p <= c2.p then
        return { { p = c1.p, i = c1.i } }
      elseif c1.p >= c2.p + #c2.d then
        return { { p = c1.p - #c2.d, i = c1.i } }
      else
        -- Insert inside deleted region: move to delete start
        return { { p = c2.p, i = c1.i } }
      end
    end
  end

  -- c1 is delete
  if c1.d then
    if c2.i then
      -- Delete vs Insert
      local c1_end = c1.p + #c1.d
      if c2.p >= c1_end then
        -- Insert is after our delete
        return { { p = c1.p, d = c1.d } }
      elseif c2.p <= c1.p then
        -- Insert is before our delete
        return { { p = c1.p + #c2.i, d = c1.d } }
      else
        -- Insert splits our delete
        local offset = c2.p - c1.p
        local before = c1.d:sub(1, offset)
        local after = c1.d:sub(offset + 1)
        return {
          { p = c1.p, d = before },
          { p = c1.p + #before + #c2.i, d = after },
        }
      end
    elseif c2.d then
      -- Delete vs Delete
      local c1_end = c1.p + #c1.d
      local c2_end = c2.p + #c2.d

      if c2_end <= c1.p then
        -- c2 is entirely before c1
        return { { p = c1.p - #c2.d, d = c1.d } }
      elseif c2.p >= c1_end then
        -- c2 is entirely after c1
        return { { p = c1.p, d = c1.d } }
      elseif c2.p <= c1.p and c2_end >= c1_end then
        -- c2 completely contains c1 - nothing left to delete
        return {}
      elseif c2.p <= c1.p and c2_end < c1_end then
        -- c2 overlaps the start of c1
        local overlap = c2_end - c1.p
        return { { p = c2.p, d = c1.d:sub(overlap + 1) } }
      elseif c2.p > c1.p and c2_end >= c1_end then
        -- c2 overlaps the end of c1
        local keep = c2.p - c1.p
        return { { p = c1.p, d = c1.d:sub(1, keep) } }
      else
        -- c2 is inside c1
        local before = c1.d:sub(1, c2.p - c1.p)
        local after = c1.d:sub(c2_end - c1.p + 1)
        return { { p = c1.p, d = before .. after } }
      end
    end
  end

  -- Comment or unknown op type - pass through
  return { c1 }
end

--- Transform a list of ops against another list of ops
---@param ops1 table[] ops to transform
---@param ops2 table[] ops to transform against
---@param side string 'left' or 'right'
---@return table[] transformed ops1
function M.transform_ops(ops1, ops2, side)
  local result = {}
  for _, c1 in ipairs(ops1) do
    local current = { c1 }
    for _, c2 in ipairs(ops2) do
      local next_current = {}
      for _, c in ipairs(current) do
        local transformed = M.transform_component(c, c2, side)
        for _, t in ipairs(transformed) do
          table.insert(next_current, t)
        end
      end
      current = next_current
    end
    for _, c in ipairs(current) do
      table.insert(result, c)
    end
  end
  return result
end

--- Compose two operations into one (op2 applied after op1)
---@param ops1 table[] first operation
---@param ops2 table[] second operation (applied after ops1)
---@return table[] composed operation
function M.compose(ops1, ops2)
  -- Simple composition: just concatenate
  -- This works because ops are position-based and applied sequentially
  local result = {}
  for _, op in ipairs(ops1) do
    table.insert(result, op)
  end
  for _, op in ipairs(ops2) do
    table.insert(result, op)
  end
  return result
end

--- Convert byte offset to (0-indexed row, col) in content string
---@param content string
---@param byte_offset number 0-based byte offset
---@return number row (0-indexed)
---@return number col (0-indexed)
function M.byte_offset_to_pos(content, byte_offset)
  local row = 0
  local last_newline = 0 -- position after last newline (1-indexed in content)

  for i = 1, byte_offset do
    if content:byte(i) == 10 then -- '\n'
      row = row + 1
      last_newline = i
    end
  end

  local col = byte_offset - last_newline
  return row, col
end

--- Convert (0-indexed row, col) to byte offset in content string
---@param content string
---@param row number 0-indexed
---@param col number 0-indexed
---@return number byte offset (0-based)
function M.pos_to_byte_offset(content, row, col)
  local current_row = 0
  local offset = 0

  for i = 1, #content do
    if current_row == row then
      return offset + col
    end
    if content:byte(i) == 10 then
      current_row = current_row + 1
    end
    offset = offset + 1
  end

  -- Past end of content, return at the requested position
  return offset + col
end

return M
