--- *tachydromos.nvim* Execute .http files via the `tachy` CLI.
---
--- Runs `.http` request files by shelling out to the `tachy` binary (see
--- `docs/cli-contract.md` for the full integration contract this module is
--- built against) and shows results in a reused scratch buffer.
---
--- Follows mini.nvim's module conventions: a single `return module` table,
--- `setup()` merging user config over `H.default_config`, an `H` table of
--- private helpers, and heavier submodules (`cli`, `env`, `result`,
--- `picker`) required lazily on first use rather than at the top of this
--- file.
---
---@toc_entry tachydromos.nvim
---@brief ]=]

local M = {}
local H = {}

-- Module-local caches for lazily-required submodules -----------------------

local Cli, Env, Result, Picker, Util

local function cli() Cli = Cli or require('tachydromos.cli'); return Cli end
local function env_mod() Env = Env or require('tachydromos.env'); return Env end
local function result_mod() Result = Result or require('tachydromos.result'); return Result end
local function picker_mod() Picker = Picker or require('tachydromos.picker'); return Picker end
local function util_mod() Util = Util or require('tachydromos.util'); return Util end

-- Config ---------------------------------------------------------------

---@class tachydromos.ResultConfig
---@field style 'split'|'vsplit'|'float' Where the result window opens. Default `'split'`.
---@field size number Fraction of the screen the split/float occupies. Default `0.4`.

---@class tachydromos.Mappings
---@field run string|false Run request under cursor. Default `'<leader>rr'`.
---@field run_buffer string|false Run every request in the buffer. Default `'<leader>ra'`.
---@field picker string|false Pick a request by name and run it. Default `'<leader>rp'`.
---@field select_env string|false Open the environment picker. Default `'<leader>re'`.

---@class tachydromos.Config
---@field tachy_cmd string Name or path of the `tachy` executable. Default `'tachy'`.
---@field default_env string|nil Environment used when a buffer has none selected via `:Tachydromos env`. Default `nil` (no `--env` flag).
---@field result tachydromos.ResultConfig
---@field mappings tachydromos.Mappings

-- stylua: ignore
H.default_config = {
  tachy_cmd = 'tachy',
  default_env = nil,
  result = {
    style = 'split',
    size = 0.4,
  },
  mappings = {
    run         = '<leader>rr',
    run_buffer  = '<leader>ra',
    picker      = '<leader>rp',
    select_env  = '<leader>re',
  },
}

--- Current config, populated by `setup()`. Usable (with defaults) even
--- before `setup()` is called, mirroring mini.nvim modules.
---@type tachydromos.Config
M.config = H.default_config

-- Setup ------------------------------------------------------------------

--- Module setup.
---
--- Nothing in this plugin is active until this is called: no user
--- commands, no buffer-local keymaps in `.http` files.
---@param config tachydromos.Config|nil
---@return tachydromos M
M.setup = function(config)
  _G.Tachydromos = M

  config = H.setup_config(config)
  H.apply_config(config)
  H.create_user_commands()

  return M
end

---@private
H.check_type = function(name, val, ref, allow_nil)
  if (val == nil and allow_nil) or type(val) == ref then return end
  error(string.format('`%s` should be of type %s, not %s', name, ref, type(val)))
end

---@private
H.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = vim.tbl_deep_extend('force', vim.deepcopy(H.default_config), config or {})

  H.check_type('tachy_cmd', config.tachy_cmd, 'string')
  H.check_type('default_env', config.default_env, 'string', true)

  H.check_type('result', config.result, 'table')
  H.check_type('result.style', config.result.style, 'string')
  H.check_type('result.size', config.result.size, 'number')
  if not vim.tbl_contains({ 'split', 'vsplit', 'float' }, config.result.style) then
    error(string.format('`result.style` should be one of "split"|"vsplit"|"float", not %q', config.result.style))
  end

  H.check_type('mappings', config.mappings, 'table')
  for key, _ in pairs(H.default_config.mappings) do
    local v = config.mappings[key]
    if v ~= false then H.check_type('mappings.' .. key, v, 'string', true) end
  end

  return config
end

---@private
H.apply_config = function(config)
  M.config = config
  cli().binary_name = config.tachy_cmd
  H.create_autocommands()
end

---@private
H.create_autocommands = function()
  local group = vim.api.nvim_create_augroup('Tachydromos', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'http',
    desc = 'Attach tachydromos.nvim keymaps to .http buffers',
    callback = function(args) H.attach_buffer(args.buf) end,
  })

  -- setup() may run after .http buffers are already open (e.g. lazy-loaded
  -- on the FileType event itself) — attach to those too.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == 'http' then H.attach_buffer(buf) end
  end
end

---@private
H.attach_buffer = function(buf)
  local maps = M.config.mappings
  local function set(lhs, rhs, desc)
    if not lhs or lhs == '' then return end
    vim.keymap.set('n', lhs, rhs, { buffer = buf, silent = true, desc = 'tachydromos: ' .. desc })
  end
  set(maps.run, M.run_current, 'run request under cursor')
  set(maps.run_buffer, M.run_buffer, 'run all requests in buffer')
  set(maps.picker, M.pick_and_run, 'pick & run a request')
  set(maps.select_env, M.select_env, 'select environment')
end

---@private
H.create_user_commands = function()
  vim.api.nvim_create_user_command('Tachydromos', function(cmd_opts)
    local sub, arg = cmd_opts.fargs[1], cmd_opts.fargs[2]
    if sub == 'run' then
      M.run_current()
    elseif sub == 'buffer' then
      M.run_buffer()
    elseif sub == 'picker' then
      M.pick_and_run()
    elseif sub == 'env' then
      if arg then M.set_env(arg) else M.select_env() end
    elseif sub == 'last' then
      result_mod().show()
    else
      vim.notify(
        string.format('tachydromos: unknown subcommand %q. Available: run, buffer, picker, env [name], last', tostring(sub)),
        vim.log.levels.ERROR
      )
    end
  end, {
    nargs = '+',
    complete = function(arglead, cmdline)
      local subs = { 'run', 'buffer', 'picker', 'env', 'last' }
      if cmdline:match('^%s*%S+%s+%S*$') then
        return vim.tbl_filter(function(s) return s:find(arglead, 1, true) == 1 end, subs)
      end
      return {}
    end,
    desc = 'tachydromos.nvim: run | buffer | picker | env [name] | last',
  })
end

-- Public API ---------------------------------------------------------------

---@private
H.current_file = function()
  local file = vim.api.nvim_buf_get_name(0)
  if file == '' then
    vim.notify('tachydromos: current buffer is not associated with a file', vim.log.levels.ERROR)
    return nil
  end
  return file
end

---@private
H.execute_run = function(file, opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local env_name = opts.env or vim.b[buf].tachydromos_env or M.config.default_env

  local result = result_mod()
  result.start_run(file, { env = env_name, request = opts.request })

  cli().run(file, { env = env_name, request = opts.request }, {
    on_object = function(obj) result.add_entry(obj) end,
    on_done = function(ok, err_message) result.finish_run(ok, err_message) end,
  })
end

--- Run the request under (at-or-above) the cursor.
---
--- Uses `tachy list <file> --format json` to find the nearest `### NAME` at
--- or above the cursor, then `tachy run <file> --request <name>`. Falls
--- back to running the whole file (no `--request`) when the request has no
--- name (`--request` can't target it) or its raw URL looks like it
--- references another request's chained response — see the contract's
--- `--request` chaining caveat.
M.run_current = function()
  local file = H.current_file()
  if not file then return end
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  cli().list(file, function(ok, items, err)
    if not ok and #items == 0 then
      vim.notify('tachydromos: ' .. (err or 'failed to list requests'), vim.log.levels.ERROR)
      return
    end

    local req = util_mod().request_at_line(items, bufnr, cursor_line)
    if not req then
      vim.notify('tachydromos: no request found at or above the cursor', vim.log.levels.WARN)
      return
    end
    if req.type == 'file_error' then
      vim.notify('tachydromos: ' .. req.error, vim.log.levels.ERROR)
      return
    end
    if not req.name then
      vim.notify(
        'tachydromos: request under cursor has no `### NAME`; --request cannot target it. Running the whole file instead.',
        vim.log.levels.WARN
      )
      H.execute_run(file, {})
      return
    end
    if util_mod().looks_chained(req.url) then
      vim.notify(
        "tachydromos: this request's URL looks like it references another request's chained response; running the whole file so chaining resolves.",
        vim.log.levels.INFO
      )
      H.execute_run(file, {})
      return
    end
    H.execute_run(file, { request = req.name })
  end)
end

--- Run every request in the current buffer's file (`tachy run <file>`, no
--- `--request` — the only way chaining between requests resolves, per the
--- contract).
M.run_buffer = function()
  local file = H.current_file()
  if not file then return end
  H.execute_run(file, {})
end

--- Open a `vim.ui.select` picker over the current file's requests (via
--- `tachy list`) and run the chosen one with `--request <name>`.
M.pick_and_run = function()
  local file = H.current_file()
  if not file then return end
  picker_mod().pick_request(file, function(item)
    if util_mod().looks_chained(item.url) then
      vim.notify(
        "tachydromos: this request's URL looks like it references another request's chained response; running the whole file so chaining resolves.",
        vim.log.levels.INFO
      )
      H.execute_run(file, {})
      return
    end
    H.execute_run(file, { request = item.name })
  end)
end

--- Open a `vim.ui.select` picker over environment names discovered by
--- walking up from the current file (see `tachydromos.env`), and set the
--- chosen one as the active environment for this buffer's future runs.
M.select_env = function()
  local file = H.current_file()
  if not file then return end

  local names = env_mod().list_names(file)
  if #names == 0 then
    vim.notify('tachydromos: no environments found near ' .. file .. ' (no http-client.env.json?)', vim.log.levels.WARN)
    return
  end

  local NONE = '(none — clear selection)'
  local choices = { NONE }
  vim.list_extend(choices, names)

  vim.ui.select(choices, { prompt = 'Tachydromos: select environment' }, function(choice)
    if not choice then return end
    if choice == NONE then
      M.set_env(nil)
    else
      M.set_env(choice)
    end
  end)
end

--- Set (or, with `nil`/`''`, clear) the active environment for the current
--- buffer's future runs, equivalent to `:Tachydromos env {name}`.
---@param name string|nil
M.set_env = function(name)
  local buf = vim.api.nvim_get_current_buf()
  if name == nil or name == '' then
    vim.b[buf].tachydromos_env = nil
    vim.notify('tachydromos: cleared environment selection')
  else
    vim.b[buf].tachydromos_env = name
    vim.notify('tachydromos: environment set to "' .. name .. '"')
  end
end

return M
