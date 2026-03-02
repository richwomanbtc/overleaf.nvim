local config = require('overleaf.config')

describe('config', function()
  -- Save original config and restore after each test
  local original_config

  before_each(function() original_config = vim.deepcopy(config._config) end)

  after_each(function() config._config = original_config end)

  describe('defaults', function()
    it(
      'has base_url defaulting to overleaf.com',
      function() assert.are.equal('https://www.overleaf.com', config.get().base_url) end
    )

    it('has pdf_viewer defaulting to nil', function() assert.is_nil(config.get().pdf_viewer) end)

    it('has node_path defaulting to node', function() assert.are.equal('node', config.get().node_path) end)

    it('has log_level defaulting to info', function() assert.are.equal('info', config.get().log_level) end)
  end)

  describe('setup', function()
    it('overrides base_url for self-hosted instance', function()
      config.setup({ base_url = 'https://my-overleaf.example.com' })
      assert.are.equal('https://my-overleaf.example.com', config.get().base_url)
    end)

    it('overrides pdf_viewer', function()
      config.setup({ pdf_viewer = 'zathura' })
      assert.are.equal('zathura', config.get().pdf_viewer)
    end)

    it('preserves unset fields', function()
      config.setup({ base_url = 'http://localhost:8080' })
      assert.are.equal('node', config.get().node_path)
      assert.are.equal('info', config.get().log_level)
    end)

    it('handles nil opts gracefully', function()
      config.setup(nil)
      assert.are.equal('https://www.overleaf.com', config.get().base_url)
    end)
  end)

  describe('load_cookie', function()
    it('returns cookie metadata when cookie is set in config', function()
      config.setup({ cookie = 'overleaf_session2=s%3Afrom_config' })
      local cookie, meta = config.load_cookie({ return_metadata = true })
      assert.are.equal('overleaf_session2=s%3Afrom_config', cookie)
      assert.are.equal('config', meta.source)
      assert.is_nil(meta.path)
    end)

    it('loads cookie from env file with source metadata', function()
      local tmp = vim.fn.tempname()
      local f = io.open(tmp, 'w')
      assert.is_not_nil(f)
      f:write('OVERLEAF_COOKIE=overleaf_session2=s%3Afrom_env\n')
      f:close()

      config.setup({ cookie = nil, env_file = tmp })
      local cookie, meta = config.load_cookie({ return_metadata = true })

      assert.are.equal('overleaf_session2=s%3Afrom_env', cookie)
      assert.are.equal('env-file', meta.source)
      assert.are.equal(tmp, meta.path)
      assert.are.equal(1, #meta.checks)
      assert.are.equal(tmp, meta.checks[1].path)
      assert.is_true(meta.checks[1].found)

      vim.fn.delete(tmp)
    end)

    it('tracks checked env paths when cookie is not found', function()
      local missing = vim.fn.tempname()
      config.setup({ cookie = nil, env_file = missing })

      local cookie, meta = config.load_cookie({ return_metadata = true })
      assert.is_nil(cookie)
      assert.are.equal(1, #meta.checks)
      assert.are.equal(missing, meta.checks[1].path)
      assert.is_false(meta.checks[1].found)
    end)
  end)
end)
