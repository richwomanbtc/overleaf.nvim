-- Main :Overleaf command with subcommands
local subcommands = {
  connect    = function() require('overleaf').connect() end,
  disconnect = function() require('overleaf').disconnect() end,
  compile    = function() require('overleaf').compile() end,
  tree       = function() require('overleaf').toggle_tree() end,
  open       = function(args) require('overleaf').open_document(args) end,
  projects   = function() require('overleaf').select_project() end,
  status     = function() require('overleaf').status() end,
  preview    = function() require('overleaf').preview_file() end,
  new        = function(args) require('overleaf').create_doc(args) end,
  mkdir      = function(args) require('overleaf').create_folder(args) end,
  delete     = function() require('overleaf').delete_entity() end,
  rename     = function() require('overleaf').rename_entity() end,
  upload     = function(args) require('overleaf').upload_file(args) end,
  search     = function(args) require('overleaf').search(args) end,
  comments   = function(args)
    if args == 'refresh' then
      require('overleaf').refresh_comments()
    else
      require('overleaf').list_comments()
    end
  end,
  history    = function() require('overleaf').history() end,
}

vim.api.nvim_create_user_command('Overleaf', function(opts)
  local args = vim.split(opts.args, '%s+', { trimempty = true })
  local sub = args[1]

  if not sub or sub == '' then
    -- No subcommand: if connected, show status; otherwise connect
    local ol = require('overleaf')
    if ol._state.connected then
      ol.status()
    else
      ol.connect()
    end
    return
  end

  local handler = subcommands[sub]
  if handler then
    handler(args[2])
  else
    vim.notify('Unknown subcommand: ' .. sub .. '\nAvailable: ' .. table.concat(vim.tbl_keys(subcommands), ', '), vim.log.levels.ERROR)
  end
end, {
  nargs = '*',
  desc = 'Overleaf commands',
  complete = function(arglead, line, _)
    local parts = vim.split(line, '%s+', { trimempty = true })
    -- Complete subcommand name
    if #parts <= 2 and not (line:match('%s$') and #parts >= 2) then
      local prefix = arglead or ''
      local completions = {}
      for name in pairs(subcommands) do
        if name:find(prefix, 1, true) == 1 then
          table.insert(completions, name)
        end
      end
      table.sort(completions)
      return completions
    end
    -- Complete subcommand arguments
    local sub = parts[2]
    if sub == 'comments' then
      return { 'refresh' }
    end
    return {}
  end,
})
