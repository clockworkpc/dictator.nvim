-- Transport panel for dictator.nvim.
--
-- The `dictate` CLI ships its own terminal TUI, but running that inside Neovim means
-- pressing `i` to reach its keys and `<C-\><C-n>` to get back out. This draws the same
-- session state into an ordinary buffer, so the transport controls are plain normal-mode
-- mappings — in a narrow right-hand split by default, or a float if one is preferred.

local M = {}

local ns = vim.api.nvim_create_namespace("dictator_panel")

local win, buf, actions

local defaults = {
  -- A right-hand split gives the document the most usable width: the text reflows into
  -- the remaining columns instead of hiding under an overlay. "float" is the same panel
  -- in a floating window, for when a modal is wanted over the text.
  style = "split", -- split | float
  width = 0.25, -- a fraction of the editor, or an absolute number of columns
  border = "rounded", -- float only
  position = "top-right", -- float only: top-right | top-left | bottom-right | bottom | center | …
}

local opts = vim.deepcopy(defaults)

-- Panel highlights, defined only if the colourscheme has not already
local hl_links = {
  DictatorTitle = "Title",
  DictatorMeta = "Comment",
  DictatorPlaying = "DiagnosticOk",
  DictatorPaused = "DiagnosticWarn",
  DictatorDone = "DiagnosticInfo",
  DictatorStopped = "DiagnosticError",
  DictatorBar = "DiagnosticOk",
  DictatorBarEmpty = "Comment",
  DictatorText = "Normal",
  DictatorKey = "Special",
  DictatorKeyDesc = "Comment",
}

-- Transport keys. `action` names a function in the table passed to M.open().
local keys = {
  { "p", "toggle" },
  { "l", "next" },
  { "<Right>", "next" },
  { "h", "prev" },
  { "<Left>", "prev" },
  { "]", "faster" },
  { "<Up>", "faster" },
  { "[", "slower" },
  { "<Down>", "slower" },
  { "r", "restart" },
  { "q", "close" },
  { "<Esc>", "close" },
  { "Q", "stop" },
}

-- Key hints, one entry per line when the panel is too narrow for a single row
local footer = {
  { { "p", "pause" }, { "h/l", "seek" } },
  { { "[/]", "speed" }, { "r", "restart" } },
  { { "q", "close" }, { "Q", "stop" } },
}

-- ---------------------------------------------------------------- text helpers

local function truncate(s, width)
  if width <= 0 then
    return ""
  end
  while vim.fn.strdisplaywidth(s) > width do
    s = vim.fn.strcharpart(s, 0, vim.fn.strchars(s) - 1)
  end
  return s
end

local function wrap(text, width, max_lines)
  local out = {}
  for word in tostring(text or ""):gmatch("%S+") do
    local cur = out[#out]
    if cur and vim.fn.strdisplaywidth(cur .. " " .. word) <= width then
      out[#out] = cur .. " " .. word
    else
      out[#out + 1] = word
    end
  end
  if #out > max_lines then
    out[max_lines] = truncate(out[max_lines], width - 1) .. "…"
    for i = #out, max_lines + 1, -1 do
      out[i] = nil
    end
  end
  while #out < max_lines do
    out[#out + 1] = ""
  end
  return out
end

local function fmt_hms(secs)
  if not secs or secs < 0 then
    return "--:--"
  end
  local t = math.floor(secs)
  if t >= 3600 then
    return string.format("%d:%02d:%02d", math.floor(t / 3600), math.floor(t % 3600 / 60), t % 60)
  end
  return string.format("%d:%02d", math.floor(t / 60), t % 60)
end

-- A line under construction, remembering the byte range of each highlighted segment
local Line = {}
Line.__index = Line

local function line()
  return setmetatable({ text = "", marks = {} }, Line)
end

function Line:add(s, group)
  if s == nil or s == "" then
    return self
  end
  if group then
    table.insert(self.marks, { #self.text, #self.text + #s, group })
  end
  self.text = self.text .. s
  return self
end

-- ---------------------------------------------------------------- window

local function ensure_hl()
  for group, link in pairs(hl_links) do
    if vim.fn.hlexists(group) == 0 then
      vim.api.nvim_set_hl(0, group, { link = link, default = true })
    end
  end
end

-- Panel columns: a fraction of the editor (the document keeps the rest) or a count
local function panel_width()
  local w = opts.width or defaults.width
  if w > 0 and w <= 1 then
    w = math.floor(vim.o.columns * w)
  end
  -- a split also spends a column on the separator, so the document keeps its full share
  if opts.style == "split" then
    w = w - 1
  end
  return math.max(26, math.min(math.floor(w), vim.o.columns - 20))
end

local function win_config(height)
  height = math.max(1, math.min(height or 14, vim.o.lines - 4))
  local width = panel_width()
  local pos = opts.position or defaults.position
  local row, col

  if pos:find("top") then
    row = 1
  elseif pos:find("bottom") then
    row = math.max(1, vim.o.lines - height - 4)
  else
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
  end

  if pos:find("right") then
    col = math.max(0, vim.o.columns - width - 2)
  elseif pos:find("left") then
    col = 0
  else
    col = math.max(0, math.floor((vim.o.columns - width) / 2))
  end

  return {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = opts.border,
    title = " dictate ",
    title_pos = "center",
    zindex = 60,
  }
end

function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function map(lhs, action)
  vim.keymap.set("n", lhs, function()
    local fn = actions and actions[action]
    if fn then
      fn()
    end
  end, { buffer = buf, nowait = true, silent = true, desc = "dictate " .. action })
end

-- Open the panel (or focus it if it is already up). `handlers` is a table of the
-- action functions the keys above call.
function M.open(handlers, config)
  opts = vim.tbl_extend("force", defaults, config or {})
  actions = handlers or actions
  ensure_hl()

  if M.is_open() then
    vim.api.nvim_set_current_win(win)
    return win
  end

  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "dictator"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "dictate")

  if opts.style == "split" then
    vim.cmd("botright vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_width(win, panel_width())
    vim.wo[win].winfixwidth = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
  else
    -- a narrow panel needs the taller layout, corrected on the first render
    win = vim.api.nvim_open_win(buf, true, win_config(panel_width() - 4 < 56 and 14 or 8))
    vim.wo[win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder"
  end
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false

  for _, k in ipairs(keys) do
    map(k[1], k[2])
  end

  local group = vim.api.nvim_create_augroup("DictatorPanel", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    callback = function()
      win, buf = nil, nil
      if actions and actions.on_close then
        actions.on_close()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if not M.is_open() then
        return
      end
      if opts.style == "split" then
        vim.api.nvim_win_set_width(win, panel_width())
      else
        vim.api.nvim_win_set_config(win, win_config(vim.api.nvim_win_get_height(win)))
      end
    end,
  })

  return win
end

function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(win, true)
  end
  win, buf = nil, nil
end

-- ---------------------------------------------------------------- render

local icons = {
  playing = { "▶", "DictatorPlaying" },
  paused = { "⏸", "DictatorPaused" },
  starting = { "◌", "DictatorMeta" },
  done = { "■", "DictatorDone" },
}

local pad = "  "

local function bar(frac, cells)
  local filled = math.floor(math.min(math.max(frac or 0, 0), 1) * cells + 0.5)
  return string.rep("█", filled), string.rep("░", cells - filled)
end

-- The panel is meant to be narrow — the document keeps the rest of the screen — so the
-- layout folds: header, transport line, current text, key hints, each split over more
-- lines as the columns run out.
local function layout(info, inner)
  local lines = {}
  local function add(l)
    lines[#lines + 1] = l
    return l
  end

  local icon = icons[info.state] or { "■", "DictatorStopped" }
  local eta = "~" .. fmt_hms(info.left)
  local chunk = string.format("chunk %d/%d", info.idx + 1, info.total)
  local pct = string.format("%d%%", info.percent)
  local speed = "speed " .. info.speed

  if inner >= 56 then
    local head = line():add(pad):add("dictate", "DictatorTitle")
    if info.title ~= "" then
      head:add(" ── ", "DictatorMeta"):add(info.title, "DictatorMeta")
    end
    if info.voice ~= "" then
      head:add(" ── ", "DictatorMeta"):add(info.voice, "DictatorMeta")
    end
    add(head)
    add(line())

    local fill, rest = bar(info.frac, math.max(8, math.min(24, inner - 44)))
    add(line():add(pad):add(icon[1], icon[2]):add("  " .. chunk .. "  "):add(fill, "DictatorBar")
      :add(rest, "DictatorBarEmpty"):add(("  %s  %s left  %s"):format(pct, eta, speed)))
    add(line())
    for _, text in ipairs(wrap(info.text, inner, 2)) do
      add(text ~= "" and line():add(pad):add(text, "DictatorText") or line())
    end
    add(line())

    local help = line():add(pad)
    for _, row in ipairs(footer) do
      for _, k in ipairs(row) do
        help:add(help.text == pad and "" or "  "):add(k[1], "DictatorKey"):add(" " .. k[2], "DictatorKeyDesc")
      end
    end
    add(help)
  else
    add(line():add(pad):add("dictate", "DictatorTitle"))
    if info.title ~= "" then
      add(line():add(pad):add(truncate(info.title, inner), "DictatorMeta"))
    end
    if info.voice ~= "" then
      add(line():add(pad):add(truncate(info.voice, inner), "DictatorMeta"))
    end
    add(line())

    local transport = line():add(pad):add(icon[1], icon[2]):add("  " .. chunk .. "  " .. pct)
    if inner >= #chunk + #pct + 16 then
      transport:add("  " .. speed)
    end
    add(transport)
    local fill, rest = bar(info.frac, math.max(8, inner - #eta - 2))
    add(line():add(pad):add(fill, "DictatorBar"):add(rest, "DictatorBarEmpty"):add("  " .. eta))
    if not transport.text:find("speed") then
      add(line():add(pad):add(speed))
    end
    add(line())

    for _, text in ipairs(wrap(info.text, inner, 3)) do
      add(text ~= "" and line():add(pad):add(text, "DictatorText") or line())
    end
    add(line())

    for _, row in ipairs(footer) do
      local help = line():add(pad)
      for _, k in ipairs(row) do
        help:add(help.text == pad and "" or "  "):add(k[1], "DictatorKey"):add(" " .. k[2], "DictatorKeyDesc")
      end
      add(help)
    end
  end

  for _, l in ipairs(lines) do
    l.text = truncate(l.text, inner + 2)
  end
  return lines
end

-- info = { state, title, voice, idx, total, percent, frac, left, speed, text }
function M.render(info)
  if not M.is_open() then
    return
  end
  local rendered = layout(info, vim.api.nvim_win_get_width(win) - 4)

  if opts.style ~= "split" and vim.api.nvim_win_get_height(win) ~= #rendered then
    vim.api.nvim_win_set_config(win, win_config(#rendered))
  end

  local text = {}
  for i, l in ipairs(rendered) do
    text[i] = l.text
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, l in ipairs(rendered) do
    -- a line may have been truncated after its segments were recorded
    local len = #l.text
    for _, m in ipairs(l.marks) do
      if m[1] < len then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, m[1], { end_col = math.min(m[2], len), hl_group = m[3] })
      end
    end
  end
end

return M
