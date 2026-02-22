-- Minimal init for running tests with Plenary
local plenary_dir = vim.fn.getcwd() .. '/.tests/plenary.nvim'
vim.opt.rtp:append('.')
vim.opt.rtp:append(plenary_dir)
vim.cmd('runtime plugin/plenary.vim')
