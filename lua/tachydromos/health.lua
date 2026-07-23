--- tachydromos.health: `:checkhealth tachydromos`.

local Health = {}

--- Neovim's `:checkhealth` renamed `vim.health.report_*` to `vim.health.*`
--- around 0.10; support both so this doesn't hard-error on older Neovim
--- before the version check below even runs.
local function fn(name, fallback)
  return vim.health[name] or vim.health['report_' .. fallback]
end

Health.check = function()
  local start = fn('start', 'start')
  local ok_fn = fn('ok', 'ok')
  local warn = fn('warn', 'warn')
  local error_fn = fn('error', 'error')
  local info = fn('info', 'info')

  start('tachydromos.nvim')

  if vim.fn.has('nvim-0.10') == 1 then
    ok_fn('Neovim >= 0.10 (vim.system available)')
  else
    error_fn('Neovim 0.10+ is required (this plugin uses vim.system()).')
    return
  end

  local Cli = require('tachydromos.cli')

  if not Cli.is_available() then
    error_fn(
      string.format(
        '`%s` not found on $PATH. Build it in the `tachydromos` repo (`make build`) and put `bin/tachy` on PATH.',
        Cli.binary_name
      )
    )
    return
  end

  ok_fn('`' .. Cli.binary_name .. '` found: ' .. vim.fn.exepath(Cli.binary_name))

  local version, version_err = Cli.get_version()
  if version then
    info('tachy version: ' .. version)
  else
    warn('Could not determine tachy version: ' .. tostring(version_err))
  end

  local supports_list, list_err = Cli.supports_list()
  if supports_list then
    ok_fn('`tachy list` is supported (required for cursor/picker request discovery).')
  else
    error_fn(
      '`tachy list` is not supported by this build of tachy — upgrade it. ('
        .. tostring(list_err)
        .. ') Without it, "run request under cursor" and the request picker cannot work.'
    )
  end
end

return Health
