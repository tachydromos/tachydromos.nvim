--- tachydromos.picker: `vim.ui.select`-based request picker.
---
--- Deliberately not a bespoke fuzzy-finder UI — `vim.ui.select` lets users
--- with telescope.nvim/fzf-lua/mini.pick/snacks.nvim wired up as their
--- `vim.ui.select` provider get a rich picker for free, and everyone else
--- gets a sane built-in fallback, without this plugin taking on a picker
--- dependency itself.

local Picker = {}

--- List requests in `file` via `tachy list --format json` and prompt the
--- user to choose one.
---@param file string
---@param callback fun(item: table) Called with the chosen `requestMeta` item.
Picker.pick_request = function(file, callback)
  require('tachydromos.cli').list(file, function(ok, items, err)
    if not ok and #items == 0 then
      vim.notify('tachydromos: ' .. (err or 'failed to list requests'), vim.log.levels.ERROR)
      return
    end
    if items[1] and items[1].type == 'file_error' then
      vim.notify('tachydromos: ' .. items[1].error, vim.log.levels.ERROR)
      return
    end
    if #items == 0 then
      vim.notify('tachydromos: no requests found in ' .. file, vim.log.levels.WARN)
      return
    end

    vim.ui.select(items, {
      prompt = 'Tachydromos: run request',
      format_item = function(item) return string.format('%-24s %s %s', item.label, item.method, item.url) end,
    }, function(choice)
      if choice then callback(choice) end
    end)
  end)
end

return Picker
