--- tachydromos.env: replicate `tachy`'s environment-file discovery in Lua.
---
--- The contract states there is no CLI flag to list environment names, so
--- the plugin reads `http-client.env.json` / `http-client.private.env.json`
--- itself, using the exact walk-and-merge algorithm the contract documents
--- (see "Environment / variable selection" in docs/cli-contract.md).

local Env = {}
local H = {}

--- Best-effort read+decode of a JSON file.
---@param path string
---@return table|nil
H.read_json = function(path)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read then return nil end
  local ok_decode, decoded = pcall(vim.json.decode, table.concat(lines, '\n'))
  if not ok_decode or type(decoded) ~= 'table' then return nil end
  return decoded
end

--- Directories from `dir` up to (and including) the filesystem root,
--- closest first.
---@param dir string
---@return string[]
H.ancestor_dirs = function(dir)
  local levels, cur = {}, dir
  while true do
    table.insert(levels, cur)
    local parent = vim.fn.fnamemodify(cur, ':h')
    if parent == cur or parent == '' then break end
    cur = parent
  end
  return levels
end

--- Merge every `http-client(.private).env.json` found walking up from
--- `http_file`'s own directory (NOT cwd, NOT `--dir` — per contract).
--- At each level: private overrides public. Across levels: a directory
--- closer to the file overrides a farther ancestor only on conflicting
--- keys; non-conflicting keys from ancestors still apply.
---@param http_file string
---@return table<string, table> env_name -> variables
Env.discover = function(http_file)
  local dir = vim.fn.fnamemodify(vim.fn.fnamemodify(http_file, ':p'), ':h')
  local levels = H.ancestor_dirs(dir)

  local merged = {}
  -- Walk farthest ancestor -> closest so that, in each deep-extend call,
  -- the closer level's keys win on conflict while unrelated keys persist.
  for i = #levels, 1, -1 do
    local d = levels[i]
    local public = H.read_json(d .. '/http-client.env.json') or {}
    local private = H.read_json(d .. '/http-client.private.env.json') or {}
    local level = vim.tbl_deep_extend('force', public, private)
    merged = vim.tbl_deep_extend('force', merged, level)
  end
  return merged
end

--- Top-level environment names available to `http_file`, `$`-prefixed
--- reserved keys (e.g. `$schema`) excluded, sorted.
---@param http_file string
---@return string[]
Env.list_names = function(http_file)
  local data = Env.discover(http_file)
  local names = {}
  for k, _ in pairs(data) do
    if type(k) == 'string' and not vim.startswith(k, '$') then table.insert(names, k) end
  end
  table.sort(names)
  return names
end

return Env
