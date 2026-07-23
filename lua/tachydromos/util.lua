--- tachydromos.util: small stateless helpers shared by other modules.

local Util = {}
local H = {}

--- Find the `### ` header line at-or-above `cursor_line`, and the next
--- `### ` header line after it (if any), by scanning the buffer's own
--- text. These bound the request block the cursor is logically "in",
--- independent of where inside that block the cursor happens to sit.
---@param bufnr integer
---@param cursor_line integer 1-based
---@return integer|nil header_line 1-based, nil if cursor is before any header
---@return integer|nil next_header_line 1-based, nil if none follows
H.block_bounds = function(bufnr, cursor_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) -- lines[i] is buffer line i (1-based)

  local header_line = nil
  for i = math.min(cursor_line, #lines), 1, -1 do
    if lines[i] and lines[i]:match('^%s*###') then
      header_line = i
      break
    end
  end

  local next_header_line = nil
  for i = (header_line and header_line + 1 or 1), #lines do
    if lines[i]:match('^%s*###') then
      next_header_line = i
      break
    end
  end

  return header_line, next_header_line
end

--- Find the request block the cursor is in and return its `tachy list`
--- item.
---
--- `tachy list`'s `line` field points at the request line itself (the
--- `GET`/`POST` line), NOT the preceding `### NAME` header — so matching
--- purely on "largest item.line <= cursor_line" resolves to the *previous*
--- block whenever the cursor sits on the header line itself, or anywhere
--- in the gap between the header and the request line. This is fixed
--- plugin-side (no CLI change needed) by first finding the enclosing
--- `### `-delimited block from the buffer's own text via `H.block_bounds`,
--- then picking the `request` item whose `line` falls strictly inside that
--- block's bounds — which is correct regardless of where in the block the
--- cursor is.
---
--- If `items[1]` is a `file_error` (the whole file failed to parse, per
--- contract: `list`/`run` emit exactly one `file_error` instead of any
--- `request` objects in that case), it is returned immediately so the
--- caller can surface the parse error instead of a bogus "not found".
---@param items table[]
---@param bufnr integer
---@param cursor_line integer 1-based
---@return table|nil
Util.request_at_line = function(items, bufnr, cursor_line)
  if items[1] and items[1].type == 'file_error' then return items[1] end

  local header_line, next_header_line = H.block_bounds(bufnr, cursor_line)
  local lower = header_line or 0
  local upper = next_header_line or math.huge

  local best = nil
  for _, item in ipairs(items) do
    if item.type == 'request' and item.line and item.line > lower and item.line < upper then
      if not best or item.line < best.line then best = item end
    end
  end
  if best then return best end

  -- Defensive fallback (e.g. buffer has unsaved edits so its text doesn't
  -- match what `tachy list` just parsed off disk, and no item landed
  -- inside the detected block bounds): the previous, coarser heuristic —
  -- largest item.line <= cursor_line — beats resolving to nothing.
  for _, item in ipairs(items) do
    if item.type == 'request' and item.line and item.line <= cursor_line then
      if not best or item.line > best.line then best = item end
    end
  end
  return best
end

--- Heuristic only: does `url` (the raw, unresolved URL from `tachy list`)
--- look like it references another request's chained response
--- (`{{NAME.response...}}`)? Per contract, `--request <name>` never runs a
--- dependency first, so this is used to decide whether to fall back to
--- running the whole file.
---
--- Known limitation: `tachy list` exposes only the raw request-line URL,
--- not headers or body, so a chaining reference that lives only in a
--- header or the request body is invisible to this check. Documented as a
--- judgment call in the plugin's report; not something the contract
--- currently gives the plugin a way to see up front.
---@param url string|nil
---@return boolean
Util.looks_chained = function(url)
  if not url then return false end
  return url:match('%{%{%s*[%w_]+%.response') ~= nil
end

return Util
