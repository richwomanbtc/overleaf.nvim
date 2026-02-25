local ot = require('overleaf.ot')
local buffer = require('overleaf.buffer')

-- Counter for unique buffer names
local test_counter = 0

-- Minimal mock document for testing buffer creation and on_bytes
local function make_doc(content, path)
  test_counter = test_counter + 1
  return {
    doc_id = 'test_doc_' .. test_counter,
    path = path or ('/test_' .. test_counter .. '.tex'),
    bufnr = nil,
    version = 1,
    content = content,
    server_content = content,
    joined = true,
    inflight_op = nil,
    pending_ops = nil,
    applying_remote = false,
    _rejoining = false,
    _flush_timer = nil,
    _submitted_ops = {},
    _rejoin_called = false,

    submit_op = function(self, ops) table.insert(self._submitted_ops, vim.deepcopy(ops)) end,

    check_content = function(self)
      if not self.joined or self._rejoining then return true end
      if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then return true end
      if self.applying_remote then return true end
      local buf_lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      if buf_content ~= self.content then
        self._rejoin_called = true
        return false
      end
      return true
    end,

    rejoin = function(self) self._rejoin_called = true end,
  }
end

describe('buffer', function()
  describe('create', function()
    it('preserves content after undo-clear for ASCII', function()
      local content = '\\documentclass{article}\n\\begin{document}\nHello World\n\\end{document}'
      local lines = vim.split(content, '\n', { plain = true })
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('preserves content after undo-clear for CJK text', function()
      local content = '日本語のテスト\n二行目'
      local lines = vim.split(content, '\n', { plain = true })
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('preserves content after undo-clear for emoji', function()
      local content = 'Hello 😀 World\nLine 2 🎉'
      local lines = vim.split(content, '\n', { plain = true })
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('preserves empty document', function()
      local content = ''
      local lines = { '' }
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('preserves single-line document', function()
      local content = 'just one line'
      local lines = { 'just one line' }
      local doc = make_doc(content)

      local bufnr = buffer.create(doc, lines)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)
      assert.is_false(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('detects divergence via check_content after undo-clear', function()
      local content = 'original content'
      local lines = { 'original content' }
      local doc = make_doc(content)
      -- Force content to differ (simulating Issue #5 garbage)
      doc.content = 'different content'

      local bufnr = buffer.create(doc, lines)

      -- check_content should have detected the mismatch
      assert.is_true(doc._rejoin_called)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('on_bytes', function()
    local doc, bufnr

    before_each(function()
      local content = 'Hello World'
      local lines = { 'Hello World' }
      doc = make_doc(content)

      bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      doc.bufnr = bufnr

      buffer.attach(bufnr, doc)
    end)

    after_each(function()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
    end)

    it('generates insert op at end', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 11, 0, 11, { '!' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(1, #ops)
      assert.are.equal(11, ops[1].p)
      assert.are.equal('!', ops[1].i)
      assert.are.equal('Hello World!', doc.content)
    end)

    it('generates insert op at beginning', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'X' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(0, ops[1].p)
      assert.are.equal('X', ops[1].i)
      assert.are.equal('XHello World', doc.content)
    end)

    it('generates delete op', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 6, 0, 11, { '' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(6, ops[1].p)
      assert.are.equal('World', ops[1].d)
      assert.are.equal('Hello ', doc.content)
    end)

    it('generates replace op (delete + insert)', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 6, 0, 11, { 'Lua' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(2, #ops)
      assert.are.equal(6, ops[1].p)
      assert.are.equal('World', ops[1].d)
      assert.are.equal(6, ops[2].p)
      assert.are.equal('Lua', ops[2].i)
      assert.are.equal('Hello Lua', doc.content)
    end)

    it('generates newline insert op', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 5, 0, 5, { '', '' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(5, ops[1].p)
      assert.are.equal('\n', ops[1].i)
      assert.are.equal('Hello\n World', doc.content)
    end)

    it('tracks content correctly after multiple edits', function()
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'X' })
      vim.api.nvim_buf_set_text(bufnr, 0, 12, 0, 12, { 'Y' })

      assert.are.equal(2, #doc._submitted_ops)
      assert.are.equal('XHello WorldY', doc.content)

      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal(doc.content, buf_content)
    end)

    it('ignores changes when applying_remote is set', function()
      doc.applying_remote = true
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'X' })
      doc.applying_remote = false

      assert.are.equal(0, #doc._submitted_ops)
      assert.are.equal('Hello World', doc.content)
    end)

    it('ignores changes when doc is not joined', function()
      doc.joined = false
      vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'X' })
      doc.joined = true

      assert.are.equal(0, #doc._submitted_ops)
      assert.are.equal('Hello World', doc.content)
    end)
  end)

  describe('on_bytes multibyte', function()
    it('generates correct char offset for CJK insert', function()
      local content = '日本語'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 0, 3, 0, 3, { 'X' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(1, ops[1].p)
      assert.are.equal('X', ops[1].i)
      assert.are.equal('日X本語', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('generates correct char offset for CJK delete', function()
      local content = '日本語'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 0, 3, 0, 6, { '' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(1, ops[1].p)
      assert.are.equal('本', ops[1].d)
      assert.are.equal('日語', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('generates correct char offset for emoji insert', function()
      local content = 'A😀B'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 0, 5, 0, 5, { 'X' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(2, ops[1].p)
      assert.are.equal('X', ops[1].i)
      assert.are.equal('A😀XB', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('generates correct char offset for mixed multibyte content', function()
      local content = 'café日本語'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 0, 5, 0, 5, { 'X' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(4, ops[1].p)
      assert.are.equal('X', ops[1].i)
      assert.are.equal('caféX日本語', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('maintains content sync across multiline multibyte edits', function()
      local content = '日本語\nHello\n世界'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n', { plain = true }))
      doc.bufnr = buf
      buffer.attach(buf, doc)

      vim.api.nvim_buf_set_text(buf, 1, 0, 1, 5, { '' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(4, ops[1].p)
      assert.are.equal('Hello', ops[1].d)
      assert.are.equal('日本語\n\n世界', doc.content)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal(doc.content, buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe('apply_remote', function()
    it('applies remote insert to buffer', function()
      local content = 'Hello World'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf

      buffer.apply_remote(doc, { { p = 5, i = ' Beautiful' } })

      vim.wait(100, function() return false end)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal('Hello Beautiful World', buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('applies remote delete to buffer', function()
      local content = 'Hello Beautiful World'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf

      buffer.apply_remote(doc, { { p = 5, d = ' Beautiful' } })

      vim.wait(100, function() return false end)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal('Hello World', buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('applies remote CJK insert to buffer', function()
      local content = 'Hello World'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf

      buffer.apply_remote(doc, { { p = 5, i = '日本' } })

      vim.wait(100, function() return false end)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal('Hello日本 World', buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('applies remote multiline insert to buffer', function()
      local content = 'Line 1\nLine 2'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n', { plain = true }))
      doc.bufnr = buf

      buffer.apply_remote(doc, { { p = 6, i = '\nNew Line' } })

      vim.wait(100, function() return false end)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are.equal('Line 1\nNew Line\nLine 2', buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════
  -- Line join operations (J, gJ, 3J)
  --
  -- These tests verify that on_bytes correctly handles line-join operations
  -- which produce replace ops (delete newline+whitespace, insert space).
  -- ═══════════════════════════════════════════════════════════════════════

  describe('on_bytes line join', function()
    it('J (join with space) generates correct delete+insert ops', function()
      local content = 'Hello\n  World'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n', { plain = true }))
      doc.bufnr = buf
      buffer.attach(buf, doc)

      -- Simulate J: delete "\n  " (newline + leading whitespace), insert " "
      vim.api.nvim_buf_set_text(buf, 0, 5, 1, 2, { ' ' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(2, #ops) -- delete + insert
      assert.are.equal(5, ops[1].p)
      assert.are.equal('\n  ', ops[1].d)
      assert.are.equal(5, ops[2].p)
      assert.are.equal(' ', ops[2].i)
      assert.are.equal('Hello World', doc.content)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal(doc.content, table.concat(buf_lines, '\n'))

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('gJ (join without space) generates delete op only', function()
      local content = 'Hello\nWorld'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n', { plain = true }))
      doc.bufnr = buf
      buffer.attach(buf, doc)

      -- Simulate gJ: delete "\n" only
      vim.api.nvim_buf_set_text(buf, 0, 5, 1, 0, { '' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(1, #ops) -- delete only
      assert.are.equal(5, ops[1].p)
      assert.are.equal('\n', ops[1].d)
      assert.are.equal('HelloWorld', doc.content)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal(doc.content, table.concat(buf_lines, '\n'))

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('J with leading whitespace collapses to single space', function()
      local content = 'Line 1\n   Line 2'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n', { plain = true }))
      doc.bufnr = buf
      buffer.attach(buf, doc)

      -- Simulate J: delete "\n   " (newline + 3 spaces), insert " "
      vim.api.nvim_buf_set_text(buf, 0, 6, 1, 3, { ' ' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(2, #ops)
      assert.are.equal(6, ops[1].p)
      assert.are.equal('\n   ', ops[1].d)
      assert.are.equal(6, ops[2].p)
      assert.are.equal(' ', ops[2].i)
      assert.are.equal('Line 1 Line 2', doc.content)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal(doc.content, table.concat(buf_lines, '\n'))

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('multi-line join (3J) generates sequential ops', function()
      local content = 'Line 1\nLine 2\nLine 3'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n', { plain = true }))
      doc.bufnr = buf
      buffer.attach(buf, doc)

      -- First join: delete "\n", insert " "
      vim.api.nvim_buf_set_text(buf, 0, 6, 1, 0, { ' ' })
      -- Second join: delete "\n", insert " "
      vim.api.nvim_buf_set_text(buf, 0, 13, 1, 0, { ' ' })

      assert.are.equal(2, #doc._submitted_ops)
      assert.are.equal('Line 1 Line 2 Line 3', doc.content)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal(doc.content, table.concat(buf_lines, '\n'))

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('J on CJK lines generates correct multibyte ops', function()
      local content = '日本語\n世界'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n', { plain = true }))
      doc.bufnr = buf
      buffer.attach(buf, doc)

      -- Simulate gJ: delete "\n" only (CJK lines)
      vim.api.nvim_buf_set_text(buf, 0, 9, 1, 0, { '' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(3, ops[1].p) -- char offset after 3 CJK chars
      assert.are.equal('\n', ops[1].d)
      assert.are.equal('日本語世界', doc.content)

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.equal(doc.content, table.concat(buf_lines, '\n'))

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════
  -- Error recovery (Fix 1-3)
  --
  -- Verify that on_bytes triggers rejoin when it detects inconsistencies
  -- instead of sending wrong ops to the server.
  -- ═══════════════════════════════════════════════════════════════════════

  describe('on_bytes error recovery', function()
    it('byte offset out of bounds triggers rejoin (Fix 1)', function()
      local content = 'Short'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      -- Set buffer to longer content than doc.content
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Much longer content' })
      doc.bufnr = buf
      buffer.attach(buf, doc)

      -- Delete at byte offset that exceeds doc.content length
      -- Buffer: "Much longer content" (19 bytes), doc: "Short" (5 bytes)
      -- byte_offset=5, old_end_byte=7, 5+7=12 > 5
      vim.api.nvim_buf_set_text(buf, 0, 5, 0, 12, { '' })

      assert.is_true(doc._rejoin_called)
      assert.are.equal(0, #doc._submitted_ops)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('insert-only past doc end triggers rejoin (Fix 1)', function()
      local content = 'Hi'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Hello World' })
      doc.bufnr = buf
      buffer.attach(buf, doc)

      -- Insert at byte 11 in buffer, but doc is only 2 bytes
      vim.api.nvim_buf_set_text(buf, 0, 11, 0, 11, { '!' })

      -- byte_offset=11 > #doc.content=2 → rejoin
      assert.is_true(doc._rejoin_called)
      assert.are.equal(0, #doc._submitted_ops)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('normal replace works correctly with pcall protection (Fix 2-3)', function()
      local content = 'Hello World'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf
      buffer.attach(buf, doc)

      -- Normal replace: should work fine with new atomic ops + pcall
      vim.api.nvim_buf_set_text(buf, 0, 6, 0, 11, { 'Lua' })

      assert.is_false(doc._rejoin_called)
      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(2, #ops)
      assert.are.equal('World', ops[1].d)
      assert.are.equal('Lua', ops[2].i)
      assert.are.equal('Hello Lua', doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════
  -- Issue #6: Content divergence edge cases
  --
  -- These tests verify what happens when doc.content and buffer have
  -- diverged. In this state, on_bytes generates WRONG ops because:
  --   1. byte_offset from Neovim is relative to buffer content
  --   2. byte_to_char(doc.content, byte_offset) uses wrong content
  --   3. doc.content:sub() extracts wrong deleted text
  --
  -- Root causes of divergence:
  --   - Issue #5: undo-clear inserts garbage before on_bytes is attached
  --   - ot.apply error in on_bytes (no pcall)
  --   - nvim_buf_get_text failure drops insert op
  -- ═══════════════════════════════════════════════════════════════════════

  describe('issue6 divergence', function()
    -- Helper: create buffer + doc with INTENTIONALLY DIVERGED state
    local function make_diverged(buf_content, doc_content)
      local doc = make_doc(doc_content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(buf_content, '\n', { plain = true }))
      doc.bufnr = buf
      buffer.attach(buf, doc)
      return doc, buf
    end

    -- ── Wrong ops sent to server when doc.content ≠ buffer ──────────

    it('wrong deleted text: server receives text from doc not buffer', function()
      -- Buffer: "ABCDE"
      -- doc:    "XYZWE"  (same length, different content)
      local doc, buf = make_diverged('ABCDE', 'XYZWE')

      -- Delete "BCD" from buffer (byte 1-3)
      vim.api.nvim_buf_set_text(buf, 0, 1, 0, 4, { '' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      -- on_bytes extracts deleted text from doc.content, not buffer
      -- doc.content:sub(2, 4) = "YZW", but user actually deleted "BCD"
      assert.are.equal('YZW', ops[1].d) -- WRONG: server sees delete of "YZW"
      assert.are_not.equal('BCD', ops[1].d) -- "BCD" was actually deleted

      -- doc.content = "XE", buffer = "AE" — diverged further
      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are_not.equal(buf_lines[1], doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('wrong op position: garbage prepend shifts middle insert', function()
      -- Issue #5 aftermath: buffer has garbage, doc does not
      -- Buffer: "GAR Hello World"  (4 byte garbage prefix)
      -- doc:    "Hello World"
      local doc, buf = make_diverged('GAR Hello World', 'Hello World')

      -- Insert 'X' at middle of "Hello" in buffer (after 'Hel', byte 7)
      vim.api.nvim_buf_set_text(buf, 0, 7, 0, 7, { 'X' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      -- byte_to_char('Hello World', 7) = 7 → insert at char 7 = after "Hello W"
      -- But in buffer, byte 7 = after "GAR Hel"
      -- Correct position for "after Hel" in doc.content would be 3
      assert.are.equal(7, ops[1].p) -- WRONG: sends position 7 to server
      assert.are_not.equal(3, ops[1].p) -- should be 3

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('wrong delete text: buffer has extra content triggers rejoin (Fix 1)', function()
      -- Buffer: "Hello Beautiful World"  (21 bytes)
      -- doc:    "Hello World"            (11 bytes, missing " Beautiful")
      local doc, buf = make_diverged('Hello Beautiful World', 'Hello World')

      -- Delete " Beautiful" from buffer (byte 5 to 15, 10 bytes)
      -- on_bytes: byte_offset=5, old_end_byte=10, 5+10=15 > 11 → out of bounds
      vim.api.nvim_buf_set_text(buf, 0, 5, 0, 15, { '' })

      -- Fix 1: boundary check detects offset out of bounds, triggers rejoin
      assert.is_true(doc._rejoin_called)
      assert.are.equal(0, #doc._submitted_ops) -- no wrong ops sent

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('wrong replace: delete and position both wrong', function()
      -- Buffer: "AABBCC"
      -- doc:    "XXYYZZ"
      local doc, buf = make_diverged('AABBCC', 'XXYYZZ')

      -- Replace "BB" with "DD" in buffer (byte 2-3)
      vim.api.nvim_buf_set_text(buf, 0, 2, 0, 4, { 'DD' })

      assert.are.equal(1, #doc._submitted_ops)
      local ops = doc._submitted_ops[1]
      assert.are.equal(2, #ops)
      -- delete: doc.content:sub(3,4) = "YY", not "BB"
      assert.are.equal('YY', ops[1].d) -- WRONG: server deletes 'YY' instead of 'BB'
      assert.are.equal('DD', ops[2].i) -- insert text is correct (from buffer)

      -- doc.content = 'XXDDZZ', buffer = 'AADDCC' — both wrong from server's view
      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are_not.equal(buf_lines[1], doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- ── Offset out of bounds when buffer is larger than doc ─────────

    it('byte offset exceeds doc length: triggers rejoin (Fix 1)', function()
      -- Buffer: "EXTRA LINE\nHello\nWorld"  (22 bytes)
      -- doc:    "Hello\nWorld"               (11 bytes)
      local doc, buf = make_diverged('EXTRA LINE\nHello\nWorld', 'Hello\nWorld')

      -- Delete "Hello" on line 2 of buffer (byte offset from buffer = 11)
      -- on_bytes: byte_offset=11, old_end_byte=5, 11+5=16 > 11 → out of bounds
      vim.api.nvim_buf_set_text(buf, 1, 0, 1, 5, { '' })

      -- Fix 1: boundary check triggers rejoin instead of silent drop
      assert.is_true(doc._rejoin_called)
      assert.are.equal(0, #doc._submitted_ops)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('CJK in buffer vs ASCII in doc: triggers rejoin (Fix 1)', function()
      -- Buffer: "日本語ABC"  (9 + 3 = 12 bytes)
      -- doc:    "XXXXABC"    (7 bytes)
      local doc, buf = make_diverged('日本語ABC', 'XXXXABC')

      -- Insert 'Z' before 'A' in buffer (byte 9)
      -- on_bytes: byte_offset=9, 9 > 7 → out of bounds
      vim.api.nvim_buf_set_text(buf, 0, 9, 0, 9, { 'Z' })

      -- Fix 1: boundary check triggers rejoin
      assert.is_true(doc._rejoin_called)
      assert.are.equal(0, #doc._submitted_ops)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- ── Cascading divergence ────────────────────────────────────────

    it('cascading divergence triggers rejoin on second edit (Fix 1)', function()
      -- Start: buffer has 1 extra prefix char
      -- Buffer: "XHello World" (12 bytes)
      -- doc:    "Hello World"  (11 bytes)
      local doc, buf = make_diverged('XHello World', 'Hello World')

      -- Edit 1: delete 'X' from buffer (byte 0, 1 byte)
      -- on_bytes: byte_offset=0, old_end_byte=1, 0+1=1 <= 11 → passes check
      vim.api.nvim_buf_set_text(buf, 0, 0, 0, 1, { '' })

      -- First edit still sends wrong op (boundary check passes for same-length)
      local ops1 = doc._submitted_ops[1]
      assert.are.equal('H', ops1[1].d) -- WRONG: deletes 'H' instead of 'X'
      -- doc.content = "ello World" (10 bytes), buffer = "Hello World" (11 bytes)

      -- Edit 2: insert '!' at end of buffer (byte 11)
      -- on_bytes: byte_offset=11, 11 > 10 → out of bounds
      vim.api.nvim_buf_set_text(buf, 0, 11, 0, 11, { '!' })

      -- Fix 1: second edit triggers rejoin, preventing further cascade
      assert.is_true(doc._rejoin_called)
      assert.are.equal(1, #doc._submitted_ops) -- only first edit submitted

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- ── Partial op (insert dropped) causes divergence ───────────────

    it('on_bytes drops insert when buffer text extraction fails', function()
      -- Simulate: delete part of an op succeeds but insert part is dropped
      -- because nvim_buf_get_text returned empty/failed.
      -- This is what on_bytes does internally — if delete but no insert,
      -- doc.content loses content that the buffer still has.
      local content = 'Hello World'
      local doc = make_doc(content)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })
      doc.bufnr = buf

      -- Manually simulate a partial on_bytes (delete without insert)
      local byte_offset = 6
      local old_end_byte = 5
      local char_offset = ot.byte_to_char(doc.content, byte_offset)
      local deleted_text = doc.content:sub(byte_offset + 1, byte_offset + old_end_byte)
      local ops = { { p = char_offset, d = deleted_text } }
      doc.content = ot.apply(doc.content, ops)
      doc:submit_op(ops)

      -- doc.content = "Hello " (lost 'World'), buffer still has "Hello World"
      assert.are.equal('Hello ', doc.content)

      -- The op sent to server deletes "World" — but user was doing a REPLACE,
      -- not a delete. Server state is now wrong.
      assert.are.equal('World', doc._submitted_ops[1][1].d)

      -- Now further edits on this buffer will generate wrong ops
      buffer.attach(buf, doc)
      vim.api.nvim_buf_set_text(buf, 0, 0, 0, 5, { 'Bye' })

      -- byte_to_char("Hello ", 0) = 0, old_end_byte = 5
      -- deleted text from doc = "Hello" (first 5 bytes of "Hello ")
      -- But user deleted "Hello" from buffer "Hello World" → same by coincidence
      -- However the insert position is wrong: buffer position 0 maps correctly
      -- but doc.content is "Hello " while buffer is "Hello World"
      -- After this op: doc.content = "Bye ", buffer = "Bye World"
      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are_not.equal(buf_lines[1], doc.content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- ── Proves Issue #5 is the root cause of Issue #6 ───────────────

    it('old undo-clear method inserts literal garbage', function()
      local content = '\\documentclass{article}'
      local lines = { content }
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

      -- Old method (the bug): single quotes don't expand \<BS>\<Esc>
      local old_undolevels = vim.bo[buf].undolevels
      vim.bo[buf].undolevels = -1
      vim.api.nvim_buf_call(buf, function() vim.cmd("exe 'normal a \\<BS>\\<Esc>'") end)
      vim.bo[buf].undolevels = old_undolevels

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      -- Garbage is literally inserted
      assert.are_not.equal(content, buf_content)
      assert.is_truthy(buf_content:find('\\<BS>\\<Esc>', 1, true))

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('new undo-clear method preserves content', function()
      local content = '\\documentclass{article}'
      local lines = { content }
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

      -- New method (the fix): API-based, no keystroke interpretation
      local old_undolevels = vim.bo[buf].undolevels
      vim.bo[buf].undolevels = -1
      vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { ' ' })
      vim.api.nvim_buf_set_text(buf, 0, 0, 0, 1, { '' })
      vim.bo[buf].undolevels = old_undolevels

      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')

      assert.are.equal(content, buf_content)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- ── End-to-end: Issue #5 → Issue #6 chain ──────────────────────

    it('garbage from old undo-clear triggers rejoin (Fix 1)', function()
      -- Reproduce the full Issue #5 → Issue #6 chain:
      -- 1. Old undo-clear inserts garbage into buffer
      -- 2. on_bytes is attached (after the garbage, so it doesn't see it)
      -- 3. User makes an edit → Fix 1 detects byte_offset out of bounds
      local content = 'Hello World'
      local doc = make_doc(content)

      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { content })

      -- Simulate old undo-clear (inserts garbage)
      vim.bo[buf].undolevels = -1
      vim.api.nvim_buf_call(buf, function() vim.cmd("exe 'normal a \\<BS>\\<Esc>'") end)
      vim.bo[buf].undolevels = 1000

      -- Buffer now has garbage, doc.content does not
      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local buf_content = table.concat(buf_lines, '\n')
      assert.are_not.equal(content, buf_content) -- garbage inserted

      -- Attach on_bytes (simulating what buffer.create does after undo-clear)
      doc.bufnr = buf
      buffer.attach(buf, doc)

      -- User types 'X' at position past original content
      -- byte_offset > #doc.content → Fix 1 triggers rejoin
      local garbage_len = #buf_content - #content
      vim.api.nvim_buf_set_text(buf, 0, 1 + garbage_len, 0, 1 + garbage_len, { 'X' })

      -- Fix 1: boundary check detects divergence, triggers rejoin
      assert.is_true(doc._rejoin_called)
      assert.are.equal(0, #doc._submitted_ops) -- no wrong ops sent

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
