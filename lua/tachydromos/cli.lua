--- tachydromos.cli: async wrapper around the `tachy` binary.
---
--- This is the ONLY module that spawns `tachy` processes. Every command/flag
--- used here is documented in `docs/cli-contract.md`; nothing is guessed.
---@diagnostic disable: undefined-doc-name

---@class tachydromos.CliRunOpts
---@field env string|nil Environment name for `--env`. `nil`/`''` omits the flag.
---@field request string|nil Request name for `--request`. `nil`/`''` omits the flag.

---@class tachydromos.CliCallbacks
---@field on_object fun(obj: table) Called once per decoded NDJSON object, in order.
---@field on_done fun(ok: boolean, err_message: string|nil) Called once, after the process exits.

local Cli = {}

--- Name or path of the `tachy` executable. Overwritten by
--- `require('tachydromos').setup({ tachy_cmd = ... })`.
Cli.binary_name = 'tachy'

--- Whether the configured `tachy` binary is reachable on `$PATH` (or, if
--- `tachy_cmd` is an absolute/relative path, executable at that path).
---@return boolean
Cli.is_available = function() return vim.fn.executable(Cli.binary_name) == 1 end

--- Synchronously run `tachy version`. Contract: prints `tachy <version>` to
--- stdout and exits 0; not useful for feature detection on its own.
---
--- Only call this from `:checkhealth` / one-off diagnostics — interactive
--- run/list paths must stay async per the contract's blocking/process-model
--- section.
---@return string|nil version
---@return string|nil err
Cli.get_version = function()
  if not Cli.is_available() then
    return nil, string.format('`%s` not found on PATH', Cli.binary_name)
  end
  local ok, res = pcall(function()
    return vim.system({ Cli.binary_name, 'version' }, { text = true }):wait()
  end)
  if not ok then return nil, tostring(res) end
  if res.code ~= 0 then return nil, vim.trim(res.stderr or '') end
  return vim.trim(res.stdout or ''), nil
end

--- Synchronously probe for `list` support, per the contract's recommended
--- detection method: `tachy list --help` exits 0 on a binary that has the
--- subcommand, exits 1 with `tachy: unknown command "list" for "tachy"` on
--- one that doesn't. Meant to be called once (e.g. from `:checkhealth`),
--- not before every invocation.
---@return boolean supported
---@return string|nil err
Cli.supports_list = function()
  if not Cli.is_available() then
    return false, string.format('`%s` not found on PATH', Cli.binary_name)
  end
  local res = vim.system({ Cli.binary_name, 'list', '--help' }, { text = true }):wait()
  if res.code == 0 then return true, nil end
  return false, vim.trim(res.stderr or '')
end

--- Spawn `tachy <args>` asynchronously and decode stdout as NDJSON, one
--- object per line, as lines arrive (contract: `--format json` writes each
--- result as soon as it's ready, not buffered until the process exits).
---@param args string[] Args after the binary name, e.g. {'run', file, '--format', 'json'}.
---@param callbacks tachydromos.CliCallbacks
---@return vim.SystemObj|nil job `nil` if `tachy` isn't on PATH (on_done is still called).
Cli.spawn_ndjson = function(args, callbacks)
  callbacks = callbacks or {}

  if not Cli.is_available() then
    if callbacks.on_done then
      vim.schedule(function()
        callbacks.on_done(false, string.format('`%s` not found on PATH', Cli.binary_name))
      end)
    end
    return nil
  end

  local stdout_buf, stderr_buf = '', ''

  local function feed_line(line)
    if line == '' then return end
    local ok, obj = pcall(vim.json.decode, line)
    if ok and type(obj) == 'table' and callbacks.on_object then
      vim.schedule(function() callbacks.on_object(obj) end)
    end
    -- A line that fails to decode means the CLI's NDJSON contract changed
    -- underneath us; there is nothing sensible for the plugin to do with
    -- it, so it is dropped rather than surfaced as a fake request result.
  end

  local function on_stdout(_, data)
    if not data then return end
    stdout_buf = stdout_buf .. data
    while true do
      local nl = stdout_buf:find('\n', 1, true)
      if not nl then break end
      feed_line(stdout_buf:sub(1, nl - 1))
      stdout_buf = stdout_buf:sub(nl + 1)
    end
  end

  local function on_stderr(_, data)
    if data then stderr_buf = stderr_buf .. data end
  end

  local cmd = { Cli.binary_name }
  vim.list_extend(cmd, args)

  return vim.system(cmd, { text = true, stdout = on_stdout, stderr = on_stderr }, function(res)
    -- Defensive: contract implies a trailing newline after every object
    -- (Go's json.Encoder.Encode always appends one), but handle a
    -- newline-less final line anyway rather than silently dropping it.
    if stdout_buf ~= '' then
      feed_line(stdout_buf)
      stdout_buf = ''
    end
    vim.schedule(function()
      if not callbacks.on_done then return end
      if res.code == 0 then
        callbacks.on_done(true, nil)
      else
        local trimmed = vim.trim(stderr_buf)
        callbacks.on_done(false, trimmed ~= '' and trimmed or ('tachy exited with code ' .. res.code))
      end
    end)
  end)
end

--- `tachy list <file> --format json`: enumerate requests without executing
--- them. No network I/O, no env resolution (contract).
---@param file string
---@param on_done fun(ok: boolean, items: table[], err: string|nil) `items` holds
---  every decoded object in order (`request` and/or a single `file_error`);
---  check `items[1].type` before trusting `ok` alone, since a `file_error`
---  entry can be present alongside a non-zero exit.
Cli.list = function(file, on_done)
  local items = {}
  Cli.spawn_ndjson({ 'list', file, '--format', 'json' }, {
    on_object = function(obj) table.insert(items, obj) end,
    on_done = function(ok, err) on_done(ok, items, err) end,
  })
end

--- `tachy run <file> [--env <name>] [--request <name>] --format json`:
--- execute requests. Streams a `request`/`file_error` object per line as
--- each request finishes.
---@param file string
---@param opts tachydromos.CliRunOpts|nil
---@param callbacks tachydromos.CliCallbacks
---@return vim.SystemObj|nil job
Cli.run = function(file, opts, callbacks)
  opts = opts or {}
  local args = { 'run', file, '--format', 'json' }
  if opts.env and opts.env ~= '' then vim.list_extend(args, { '--env', opts.env }) end
  if opts.request and opts.request ~= '' then vim.list_extend(args, { '--request', opts.request }) end
  return Cli.spawn_ndjson(args, callbacks)
end

return Cli
