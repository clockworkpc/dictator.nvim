-- Floating transport panel for dictator.nvim.
--
-- The `dictate` CLI ships its own terminal TUI, but running that inside Neovim means
-- pressing `i` to reach its keys and `<C-\><C-n>` to get back out. This draws the same
-- session state into an ordinary buffer in a float, so the transport controls are plain
-- normal-mode mappings and the window behaves like any other modal (Lazy, Mason, …).

local M = {}

local ns = vim.api.nvim_create_namespace("dictator_panel")

local win, buf, actions

local defaults = {
  width = 76,
  border = "rounded",
  position = "center", -- center | top | bottom | top-right | bottom-right | top-left | bottom-left
  cells = 24, -- progress bar width
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

local footer = {
  { "p", "pause" },
  { "h/l", "seek" },
  { "[/]", "speed" },
  { "r", "restart" },
  { "q", "close" },
  { "Q", "stop" },
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

local function win_config()
  local height = 8
  local width = math.max(40, math.min(opts.width, vim.o.columns - 4))
  local pos = opts.position or "center"
  local row, col

  if pos:find("top") then
    row = 1
  elseif pos:find("bottom") then
    row = math.max(1, vim.o.lines - height - 4)
  else
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
  end

  if pos:find("right") then
    col = math.max(0, vim.o.columns - width - 3)
  elseif pos:find("left") then
    col = 2
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

  win = vim.api.nvim_open_win(buf, true, win_config())
  vim.wo[win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder"
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
      if M.is_open() then
        vim.api.nvim_win_set_config(win, win_config())
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

-- info = { state, title, voice, idx, total, percent, frac, left, speed, text }
function M.render(info)
  if not M.is_open() then
    return
  end
  local width = vim.api.nvim_win_get_width(win)
  local inner = width - 4 -- two columns of padding either side
  local pad = "  "
  local rendered = {}

  local head = line():add(pad):add("dictate", "DictatorTitle")
  if info.title ~= "" then
    head:add(" ── ", "DictatorMeta"):add(truncate(info.title, inner - 12), "DictatorMeta")
  end
  if info.voice ~= "" then
    head:add(" ── ", "DictatorMeta"):add(info.voice, "DictatorMeta")
  end
  head.text = truncate(head.text, width - 2)
  rendered[1] = head
  rendered[2] = line()

  local icon = icons[info.state] or { "■", "DictatorStopped" }
  local cells = math.max(8, math.min(opts.cells, inner - 44))
  local filled = math.floor(math.min(math.max(info.frac or 0, 0), 1) * cells + 0.5)
  local status = line():add(pad):add(icon[1], icon[2])
  status:add(string.format("  chunk %d/%d  ", info.idx + 1, info.total))
  status:add(string.rep("█", filled), "DictatorBar")
  status:add(string.rep("░", cells - filled), "DictatorBarEmpty")
  status:add(string.format("  %d%%  ~%s left  speed %s", info.percent, fmt_hms(info.left), info.speed))
  status.text = truncate(status.text, width - 2)
  rendered[3] = status
  rendered[4] = line()

  for i, text in ipairs(wrap(info.text, inner, 2)) do
    rendered[4 + i] = text ~= "" and line():add(pad):add(text, "DictatorText") or line()
  end
  rendered[7] = line()

  local help = line():add(pad)
  for i, k in ipairs(footer) do
    if i > 1 then
      help:add("  ")
    end
    help:add(k[1], "DictatorKey"):add(" " .. k[2], "DictatorKeyDesc")
  end
  help.text = truncate(help.text, width - 2)
  rendered[8] = help

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
