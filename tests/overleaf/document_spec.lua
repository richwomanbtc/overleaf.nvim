local ot = require('overleaf.ot')

-- Stub overleaf.bridge so Document.new doesn't try real connections
package.loaded['overleaf.bridge'] = {
  request = function(_, _, cb)
    if cb then
      cb({ message = 'stub' })
    end
  end,
}

-- Stub overleaf.config
package.loaded['overleaf.config'] = {
  log = function() end,
}

-- Stub overleaf module (used by rejoin for connection check)
package.loaded['overleaf'] = {
  _state = { connected = true },
}

local Document = require('overleaf.document')

describe('document', function()
  describe('check_content', function()
    it('returns true when buffer matches doc.content', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc.content = 'Hello World'

      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'Hello World' })
      doc.bufnr = bufnr

      assert.is_true(doc:check_content())

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('returns false when buffer diverges from doc.content', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc.content = 'Hello World'

      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'Hello World MODIFIED' })
      doc.bufnr = bufnr

      local result = doc:check_content()
      assert.is_false(result)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('returns true when not joined', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = false
      doc.content = 'Hello'

      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'Different' })
      doc.bufnr = bufnr

      -- Should skip check when not joined
      assert.is_true(doc:check_content())

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('returns true when rejoining is in progress', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc._rejoining = true
      doc.content = 'Hello'

      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'Different' })
      doc.bufnr = bufnr

      assert.is_true(doc:check_content())

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('returns true when applying_remote is set', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc.applying_remote = true
      doc.content = 'Hello'

      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'Different' })
      doc.bufnr = bufnr

      assert.is_true(doc:check_content())

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('returns true when buffer is invalid', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc.content = 'Hello'
      doc.bufnr = 99999 -- invalid buffer number

      assert.is_true(doc:check_content())
    end)

    it('returns true when bufnr is nil', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc.content = 'Hello'
      doc.bufnr = nil

      assert.is_true(doc:check_content())
    end)

    it('detects multiline content divergence', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc.content = 'Line 1\nLine 2\nLine 3'

      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'Line 1', 'Line 2 CHANGED', 'Line 3' })
      doc.bufnr = bufnr

      assert.is_false(doc:check_content())

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('detects CJK content divergence', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc.content = '日本語'

      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '日本語テスト' })
      doc.bufnr = bufnr

      assert.is_false(doc:check_content())

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('submit_op', function()
    it('stores pending ops', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc.content = 'Hello'

      doc:submit_op({ { p = 5, i = '!' } })

      assert.is_not_nil(doc.pending_ops)
      assert.are.equal(1, #doc.pending_ops)
      assert.are.equal('!', doc.pending_ops[1].i)
    end)

    it('composes multiple pending ops', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc.content = 'Hello'

      doc:submit_op({ { p = 5, i = '!' } })
      doc:submit_op({ { p = 6, i = '?' } })

      assert.is_not_nil(doc.pending_ops)
      assert.are.equal(2, #doc.pending_ops)
    end)

    it('ignores ops when not joined', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = false

      doc:submit_op({ { p = 0, i = 'x' } })

      assert.is_nil(doc.pending_ops)
    end)

    it('ignores ops when rejoining', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc._rejoining = true

      doc:submit_op({ { p = 0, i = 'x' } })

      assert.is_nil(doc.pending_ops)
    end)
  end)

  describe('on_remote_op', function()
    it('applies remote insert to content and increments version', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc.version = 5
      doc.content = 'Hello World'
      doc.server_content = 'Hello World'

      local applied_ops = nil
      doc:on_remote_op(
        { v = 5, op = { { p = 5, i = ' Beautiful' } } },
        function(ops)
          applied_ops = ops
        end
      )

      assert.are.equal(6, doc.version)
      assert.are.equal('Hello Beautiful World', doc.content)
      assert.are.equal('Hello Beautiful World', doc.server_content)
      assert.is_not_nil(applied_ops)
      assert.are.equal(' Beautiful', applied_ops[1].i)
    end)

    it('applies remote delete to content', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc.version = 5
      doc.content = 'Hello Beautiful World'
      doc.server_content = 'Hello Beautiful World'

      doc:on_remote_op(
        { v = 5, op = { { p = 5, d = ' Beautiful' } } },
        function() end
      )

      assert.are.equal('Hello World', doc.content)
      assert.are.equal('Hello World', doc.server_content)
    end)

    it('transforms remote op against inflight op', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc.version = 5
      doc.content = 'HelloXY World'
      doc.server_content = 'Hello World'
      -- Inflight: inserted 'XY' at position 5
      doc.inflight_op = { { p = 5, i = 'XY' } }

      local applied_ops = nil
      -- Remote: insert 'Z' at position 5 (server doesn't know about XY yet)
      doc:on_remote_op(
        { v = 5, op = { { p = 5, i = 'Z' } } },
        function(ops)
          applied_ops = ops
        end
      )

      -- Remote 'Z' should be shifted past our 'XY' insertion
      assert.are.equal(6, doc.version)
      assert.is_not_nil(applied_ops)
      assert.are.equal(7, applied_ops[1].p) -- 5 + len('XY') = 7
      assert.are.equal('Z', applied_ops[1].i)
    end)

    it('transforms remote op against pending ops', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc.version = 5
      doc.content = 'HelloAB World'
      doc.server_content = 'Hello World'
      -- Pending: inserted 'AB' at position 5
      doc.pending_ops = { { p = 5, i = 'AB' } }

      local applied_ops = nil
      doc:on_remote_op(
        { v = 5, op = { { p = 5, i = 'Z' } } },
        function(ops)
          applied_ops = ops
        end
      )

      assert.are.equal(6, doc.version)
      assert.is_not_nil(applied_ops)
      -- Remote Z should be shifted past our pending AB
      assert.are.equal(7, applied_ops[1].p)
    end)

    it('ignores ops when not joined', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = false
      doc.version = 5
      doc.content = 'Hello'
      doc.server_content = 'Hello'

      doc:on_remote_op(
        { v = 5, op = { { p = 0, i = 'X' } } },
        function()
          error('should not be called')
        end
      )

      assert.are.equal(5, doc.version)
      assert.are.equal('Hello', doc.content)
    end)

    it('ignores empty ops', function()
      local doc = Document.new('test_doc', '/main.tex')
      doc.joined = true
      doc.version = 5
      doc.content = 'Hello'
      doc.server_content = 'Hello'

      local called = false
      doc:on_remote_op(
        { v = 5, op = {} },
        function()
          called = true
        end
      )

      assert.is_false(called)
      assert.are.equal(5, doc.version)
    end)
  end)
end)
