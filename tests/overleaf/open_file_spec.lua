local config = require('overleaf.config')
local overleaf = require('overleaf')

describe('_open_file', function()
  local original_config
  local original_jobstart, original_has

  -- Capture calls to vim.fn.jobstart
  local jobstart_calls

  before_each(function()
    original_config = vim.deepcopy(config._config)
    original_jobstart = vim.fn.jobstart
    original_has = vim.fn.has
    jobstart_calls = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function(cmd, opts)
      table.insert(jobstart_calls, { cmd = cmd, opts = opts })
      return 1 -- fake job id
    end
  end)

  after_each(function()
    config._config = original_config
    vim.fn.jobstart = original_jobstart
    vim.fn.has = original_has
  end)

  describe('with pdf_viewer set', function()
    it('launches viewer as detached background process', function()
      config.setup({ pdf_viewer = 'tdf' })

      overleaf._open_file('/tmp/test.pdf')

      assert.are.equal(1, #jobstart_calls)
      assert.are.same({ 'tdf', '/tmp/test.pdf' }, jobstart_calls[1].cmd)
      assert.is_true(jobstart_calls[1].opts.detach)
    end)

    it('works with different viewer like zathura', function()
      config.setup({ pdf_viewer = 'zathura' })

      overleaf._open_file('/tmp/test.pdf')

      assert.are.equal(1, #jobstart_calls)
      assert.are.same({ 'zathura', '/tmp/test.pdf' }, jobstart_calls[1].cmd)
      assert.is_true(jobstart_calls[1].opts.detach)
    end)
  end)

  describe('without pdf_viewer (auto-detect)', function()
    it('uses open on macOS', function()
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.has = function(feature)
        if feature == 'mac' then return 1 end
        return 0
      end

      overleaf._open_file('/tmp/test.pdf')

      assert.are.equal(1, #jobstart_calls)
      assert.are.same({ 'open', '/tmp/test.pdf' }, jobstart_calls[1].cmd)
      assert.is_true(jobstart_calls[1].opts.detach)
    end)

    it('uses wslview on WSL', function()
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.has = function(feature)
        if feature == 'wsl' then return 1 end
        return 0
      end

      overleaf._open_file('/tmp/test.pdf')

      assert.are.equal(1, #jobstart_calls)
      assert.are.same({ 'wslview', '/tmp/test.pdf' }, jobstart_calls[1].cmd)
      assert.is_true(jobstart_calls[1].opts.detach)
    end)

    it('uses xdg-open on Linux', function()
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.has = function(feature) return 0 end

      overleaf._open_file('/tmp/test.pdf')

      assert.are.equal(1, #jobstart_calls)
      assert.are.same({ 'xdg-open', '/tmp/test.pdf' }, jobstart_calls[1].cmd)
      assert.is_true(jobstart_calls[1].opts.detach)
    end)
  end)
end)
