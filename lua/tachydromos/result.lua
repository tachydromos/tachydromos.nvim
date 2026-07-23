--- tachydromos.result: renders `tachy run` output into a reused scratch
--- buffer/window, updated incrementally as NDJSON objects stream in.

local Result = {}
local H = {}

H.buf = nil
H.win = nil

H.state = {
  file = nil,
  env = nil,
  request = nil,
  entries = {}, -- decoded `request`/`file_error` objects, in arrival order
  finished = false,
  ok = nil,
  err = nil,
}

H.get_config = function()
  local ok, tachydromos = pcall(require, 'tachydromos')
  local result_cfg = ok and tachydromos.config and tachydromos.config.result
  return result_cfg or { style = 'split', size = 0.4 }
end

--- Append `text` to `lines`, splitting on embedded newlines — every string
--- that ultimately came from CLI/network output (error messages, script
--- logs) must go through this rather than a raw `table.insert`, since
--- `nvim_buf_set_lines` rejects entries containing "\n".
---@param lines string[]
---@param text any
H.add_multi = function(lines, text)
  for _, l in ipairs(vim.split(tostring(text), '\n', { plain = true })) do
    table.insert(lines, l)
  end
end

H.ensure_buf = function()
  if H.buf and vim.api.nvim_buf_is_valid(H.buf) then return H.buf end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'tachydromos-result'
  pcall(vim.api.nvim_buf_set_name, buf, 'tachydromos://result')
  H.buf = buf
  return buf
end

--- Open (or reuse) the result window without stealing focus from the
--- buffer the user is editing — a judgment call: the window becomes
--- visible immediately but the cursor stays put, matching a "peek at the
--- response while still typing" workflow more than a "jump into it" one.
H.ensure_win = function()
  if H.win and vim.api.nvim_win_is_valid(H.win) then return H.win end

  local buf = H.ensure_buf()
  local cfg = H.get_config()
  local cur_win = vim.api.nvim_get_current_win()

  if cfg.style == 'float' then
    local width = math.max(20, math.floor(vim.o.columns * 0.8))
    local height = math.max(5, math.floor(vim.o.lines * 0.8))
    H.win = vim.api.nvim_open_win(buf, false, {
      relative = 'editor',
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      style = 'minimal',
      border = 'rounded',
    })
  else
    local size = cfg.size or 0.4
    local cmd = cfg.style == 'vsplit' and ('vertical botright ' .. math.floor(vim.o.columns * size) .. 'split')
      or ('botright ' .. math.floor(vim.o.lines * size) .. 'split')
    vim.cmd(cmd)
    H.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(H.win, buf)
    vim.api.nvim_set_current_win(cur_win)
  end

  vim.wo[H.win].wrap = false
  vim.wo[H.win].number = false
  vim.wo[H.win].relativenumber = false
  return H.win
end

--- JSON-pretty-print a decoded Lua value. Best-effort only: the contract
--- notes binary bodies aren't JSON-safe, so callers must `pcall` around
--- the `vim.json.decode` that produces `value` in the first place.
H.encode_json_pretty = function(value, indent)
  indent = indent or 0
  local pad, pad_in = string.rep('  ', indent), string.rep('  ', indent + 1)
  local t = type(value)

  if t == 'table' then
    -- Not `vim.islist and vim.islist(value) or vim.tbl_islist(value)`: that
    -- classic Lua ternary idiom breaks here, since `vim.islist(value)`
    -- legitimately returns `false` for a non-array table and the `or`
    -- branch would then wrongly fall through to the deprecated fallback.
    local is_array
    if vim.islist then
      is_array = vim.islist(value)
    else
      is_array = vim.tbl_islist(value)
    end
    if is_array then
      if #value == 0 then return '[]' end
      local parts = {}
      for _, v in ipairs(value) do
        table.insert(parts, pad_in .. H.encode_json_pretty(v, indent + 1))
      end
      return '[\n' .. table.concat(parts, ',\n') .. '\n' .. pad .. ']'
    end

    local keys = vim.tbl_keys(value)
    if #keys == 0 then return '{}' end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
      table.insert(parts, pad_in .. vim.json.encode(tostring(k)) .. ': ' .. H.encode_json_pretty(value[k], indent + 1))
    end
    return '{\n' .. table.concat(parts, ',\n') .. '\n' .. pad .. '}'
  elseif t == 'string' then
    return vim.json.encode(value)
  elseif value == nil then
    return 'null'
  else
    return tostring(value)
  end
end

--- Split a response body into display lines, pretty-printing it first if
--- the `Content-Type` header looks like JSON. Falls back to the raw body
--- unmodified on any decode failure (covers non-JSON and the contract's
--- documented binary-body caveat, where a JSON round-trip may mangle
--- bytes rather than crash).
---@param body string
---@param headers table<string, string[]>|nil
---@return string[]
H.format_body = function(body, headers)
  if body == nil or body == '' then return {} end

  local is_json = false
  if headers then
    local ct = headers['Content-Type'] or headers['content-type']
    if ct then
      local ct_str = type(ct) == 'table' and table.concat(ct, ' ') or tostring(ct)
      is_json = ct_str:find('json', 1, true) ~= nil
    end
  end

  if is_json then
    local ok_decode, decoded = pcall(vim.json.decode, body)
    if ok_decode then
      local ok_encode, pretty = pcall(H.encode_json_pretty, decoded, 0)
      if ok_encode then return vim.split(pretty, '\n', { plain = true }) end
    end
  end

  return vim.split(body, '\n', { plain = true })
end

H.render_script = function(lines, label, script)
  if script.logs then
    table.insert(lines, '')
    table.insert(lines, label .. '-script logs:')
    for _, l in ipairs(script.logs) do H.add_multi(lines, '  [log] ' .. l) end
  end
  if script.tests then
    table.insert(lines, '')
    table.insert(lines, label .. '-script tests:')
    for _, test in ipairs(script.tests) do
      if test.passed then
        H.add_multi(lines, '  [PASS] ' .. test.name)
      else
        H.add_multi(lines, '  [FAIL] ' .. test.name .. (test.message and (': ' .. test.message) or ''))
      end
    end
  end
  if script.error then
    table.insert(lines, '')
    H.add_multi(lines, label .. '-script error: ' .. script.error)
  end
end

H.render_entry = function(lines, entry)
  if entry.type == 'file_error' then
    H.add_multi(lines, 'File error: ' .. entry.file)
    H.add_multi(lines, '  ' .. entry.error)
    return
  end

  local label = entry.label or entry.name or (entry.method .. ' ' .. entry.url)
  H.add_multi(lines, string.format('### %s  [%s %s]', label, entry.method, entry.url))

  local resp = entry.response
  if resp then
    table.insert(lines, string.format('%s %s (%dms)', resp.proto or '', resp.status or tostring(resp.status_code), resp.duration_ms or 0))
  else
    table.insert(lines, '(no response)')
  end

  if entry.error then H.add_multi(lines, 'error: ' .. entry.error) end

  if resp then
    if resp.headers and next(resp.headers) then
      table.insert(lines, '')
      table.insert(lines, 'Headers:')
      local names = vim.tbl_keys(resp.headers)
      table.sort(names)
      for _, name in ipairs(names) do
        H.add_multi(lines, '  ' .. name .. ': ' .. table.concat(resp.headers[name], ', '))
      end
    end

    if resp.body and resp.body ~= '' then
      table.insert(lines, '')
      table.insert(lines, 'Body:')
      for _, l in ipairs(H.format_body(resp.body, resp.headers)) do table.insert(lines, '  ' .. l) end
    end
  end

  if entry.pre_script then H.render_script(lines, 'pre', entry.pre_script) end
  if entry.post_script then H.render_script(lines, 'post', entry.post_script) end

  table.insert(lines, string.rep('-', 70))
end

H.render = function()
  if not (H.buf and vim.api.nvim_buf_is_valid(H.buf)) then return end
  local lines = {}

  H.add_multi(lines, 'tachydromos — ' .. (H.state.file or ''))
  local meta = {}
  if H.state.env then table.insert(meta, 'env=' .. H.state.env) end
  if H.state.request then table.insert(meta, 'request=' .. H.state.request) end
  table.insert(meta, H.state.finished and (H.state.ok and 'done' or 'done (failed)') or 'running…')
  table.insert(lines, table.concat(meta, '  '))
  table.insert(lines, string.rep('=', 70))
  table.insert(lines, '')

  if #H.state.entries == 0 and not H.state.finished then table.insert(lines, 'Waiting for tachy…') end

  for _, entry in ipairs(H.state.entries) do
    H.render_entry(lines, entry)
    table.insert(lines, '')
  end

  if H.state.finished and H.state.err then
    if #H.state.entries == 0 then
      table.insert(lines, 'error:')
    else
      table.insert(lines, string.rep('-', 70))
      table.insert(lines, 'tachy reported additional errors:')
    end
    H.add_multi(lines, H.state.err)
  end

  vim.bo[H.buf].modifiable = true
  vim.api.nvim_buf_set_lines(H.buf, 0, -1, false, lines)
  vim.bo[H.buf].modifiable = false
end

--- Begin a fresh run: reset state, clear/reuse the result buffer, open its
--- window. `opts.env`/`opts.request` are shown in the header only (the
--- actual CLI invocation happens in `tachydromos.cli`).
---@param file string
---@param opts { env: string|nil, request: string|nil }
Result.start_run = function(file, opts)
  opts = opts or {}
  H.state = { file = file, env = opts.env, request = opts.request, entries = {}, finished = false, ok = nil, err = nil }
  H.ensure_win()
  H.render()
end

--- Add one streamed NDJSON object (`request` or `file_error`) and re-render.
---@param obj table
Result.add_entry = function(obj)
  table.insert(H.state.entries, obj)
  H.render()
end

--- Mark the run finished and re-render. If the process failed before ever
--- producing a single object (missing binary, bad args, path not found),
--- also surface a `vim.notify` since the result buffer alone would just
--- show an empty run otherwise.
---@param ok boolean
---@param err_message string|nil
Result.finish_run = function(ok, err_message)
  H.state.finished, H.state.ok, H.state.err = true, ok, err_message
  H.render()
  if not ok and #H.state.entries == 0 then
    vim.notify('tachydromos: ' .. (err_message or 'run failed'), vim.log.levels.ERROR)
  end
end

--- Reopen the result window (e.g. `:Tachydromos last`) without starting a
--- new run.
Result.show = function()
  if not (H.buf and vim.api.nvim_buf_is_valid(H.buf)) then
    vim.notify('tachydromos: no results yet', vim.log.levels.INFO)
    return
  end
  H.ensure_win()
end

return Result
