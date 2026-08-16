-- dictator.nvim - read the current markdown buffer aloud, following along in the buffer.
--
-- The heavy lifting lives in the `dictate` CLI: it chunks the markdown, synthesizes it
-- with Piper, and exposes a session as plain state files. This module starts the CLI
-- detached, polls that state into a transport panel beside the text, and highlights the
-- source line being read.

local ui = require("dictator.ui")

local M = {}

local config = {
  cmd = "dictate", -- CLI on PATH, or an absolute path
  voice = nil, -- nil = the CLI default (alan)
  speed = nil, -- nil = the CLI default (0.7)
  win = { -- the transport panel
    style = "split", -- split (right-hand, the text reflows beside it) | float
    width = 0.25, -- a fraction of the editor, or an absolute number of columns
    border = "rounded", -- float only
    position = "top-right", -- float only
  },
  filetypes = { markdown = true }, -- set to nil to allow any buffer
  follow = true, -- scroll the source window to keep the read line visible
  poll_ms = 150,
  hl_group = "DictatorLine",
  hl_link = "Visual", -- default highlight, only if DictatorLine is undefined
}

local state = {
  src_buf = nil, -- buffer being read
  src_win = nil, -- window showing it
  timer = nil,
  gen = 0, -- session generation, so callbacks queued for an old session stay out of a new one
  rundir = nil,
  lines = nil, -- chunk index (0-based) -> source line
  sizes = nil, -- chunk index (0-based) -> character count
  chunk = nil, -- { idx, text } cache for the panel
  last_idx = nil,
  tmpfile = nil,
  tmpdir = nil,
}

local ns = vim.api.nvim_create_namespace("dictator")

-- ---------------------------------------------------------------- helpers

local function notify(msg, level)
  vim.notify("dictator: " .. msg, level or vim.log.levels.INFO)
end

local function read_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

local function read_value(name)
  if not state.rundir then
    return nil
  end
  local data = read_file(state.rundir .. "/" .. name)
  if not data then
    return nil
  end
  return (data:gsub("%s+$", ""))
end

local function read_number(name, fallback)
  return tonumber(read_value(name) or "") or fallback
end

-- Run the CLI without blocking the editor. `args` is a list.
local function cli(args, on_exit)
  local cmd = vim.list_extend({ config.cmd }, args)
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_exit = function(_, code)
      if on_exit then
        vim.schedule(function()
          on_exit(code)
        end)
      end
    end,
  })
end

local function cli_sync(args)
  local out = vim.fn.system(vim.list_extend({ config.cmd }, args))
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return (out:gsub("%s+$", ""))
end

local function now()
  local secs, usecs = vim.loop.gettimeofday()
  return secs + usecs / 1e6
end

-- ---------------------------------------------------------------- highlight

local function ensure_hl()
  if vim.fn.hlexists(config.hl_group) == 0 then
    vim.api.nvim_set_hl(0, config.hl_group, { link = config.hl_link, default = true })
  end
end

local function clear_highlight()
  if state.src_buf and vim.api.nvim_buf_is_valid(state.src_buf) then
    vim.api.nvim_buf_clear_namespace(state.src_buf, ns, 0, -1)
  end
end

local function highlight_line(line) -- 1-based source line
  if not (state.src_buf and vim.api.nvim_buf_is_valid(state.src_buf)) then
    return
  end
  local count = vim.api.nvim_buf_line_count(state.src_buf)
  if line < 1 or line > count then
    return
  end
  clear_highlight()
  vim.api.nvim_buf_set_extmark(state.src_buf, ns, line - 1, 0, {
    line_hl_group = config.hl_group,
  })

  if config.follow and state.src_win and vim.api.nvim_win_is_valid(state.src_win) then
    vim.api.nvim_win_set_cursor(state.src_win, { line, 0 })
    vim.api.nvim_win_call(state.src_win, function()
      vim.cmd("normal! zz")
    end)
  end
end

-- ---------------------------------------------------------------- session state

-- chunk index (0-based) -> source line, from the CLI's `lines` file
local function load_line_map()
  local data = read_file(state.rundir .. "/lines")
  if not data then
    return nil
  end
  local map = {}
  local i = 0
  for n in data:gmatch("[^\n]+") do
    map[i] = tonumber(n) or 0
    i = i + 1
  end
  return map
end

-- chunk index (0-based) -> characters, from the CLI's `sizes` file
local function load_sizes()
  local data = read_file(state.rundir .. "/sizes")
  if not data then
    return nil
  end
  local sizes, total = {}, 0
  local i = 0
  for n in data:gmatch("[^\n]+") do
    sizes[i] = tonumber(n) or 0
    total = total + sizes[i]
    i = i + 1
  end
  sizes.total = total
  return sizes
end

local function chunk_text(idx)
  if state.chunk and state.chunk.idx == idx then
    return state.chunk.text
  end
  local data = read_file(string.format("%s/chunks/%04d.txt", state.rundir, idx)) or ""
  local text = data:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  state.chunk = { idx = idx, text = text }
  return text
end

-- Everything the panel draws, derived from the CLI's state files. Progress is
-- character-weighted, with the within-chunk fraction taken from how far into the
-- current wav's duration we are — the same arithmetic as the CLI's own TUI.
local function session_info()
  local st = read_value("state") or "none"
  local idx = read_number("idx", 0)
  local dur = read_number("dur", 0)
  local started = read_number("started", 0)
  local acc = read_number("paused_acc", 0)
  local paused_at = read_number("paused_at", 0)

  state.sizes = state.sizes or load_sizes()
  local sizes = state.sizes or {}
  local all = sizes.total or 0

  local elapsed = 0
  if started > 0 then
    local ref = (st == "paused" and paused_at > 0) and paused_at or now()
    elapsed = math.max(0, ref - started - acc)
  end

  local done = 0
  for i = 0, idx - 1 do
    done = done + (sizes[i] or 0)
  end
  local cur = sizes[idx] or 0
  local frac = dur > 0 and math.min(elapsed / dur, 1) or 0
  local done_now = done + cur * frac

  return {
    state = st,
    idx = idx,
    total = read_number("total", 0),
    speed = read_value("speed") or "",
    title = read_value("title") or "",
    voice = read_value("voice") or "",
    percent = all > 0 and math.floor(done_now * 100 / all) or 0,
    frac = all > 0 and done_now / all or 0,
    left = (dur > 0 and cur > 0) and (all - done_now) * (dur / cur) or -1,
    text = chunk_text(idx),
  }
end

local function stop_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

local function follow(idx)
  if idx == state.last_idx then
    return
  end
  state.last_idx = idx
  state.lines = state.lines or load_line_map()
  local line = state.lines and state.lines[idx]
  if line and line > 0 then
    highlight_line(line)
  end
end

-- One poll: follow the read line, redraw the panel, and notice a finished session.
local function update()
  if not state.rundir then
    return
  end
  local info = session_info()

  if info.state == "none" or info.state == "stopped" then
    M.stop({ keep_session = true })
    return
  end

  follow(info.idx)
  ui.render(info)

  if info.state == "done" then
    stop_timer()
    local gen = state.gen
    vim.defer_fn(function()
      if state.gen == gen then
        M.stop({ keep_session = true })
      end
    end, 1500)
  end
end

local function start_timer()
  stop_timer()
  local gen = state.gen
  state.timer = vim.loop.new_timer()
  state.timer:start(100, config.poll_ms, function()
    vim.schedule(function()
      -- a poll queued for a session that has since been replaced must not touch this one
      if state.gen == gen then
        update()
      end
    end)
  end)
end

-- Redraw sooner than the next poll, once the CLI has had a moment to act
local function refresh()
  local gen = state.gen
  vim.defer_fn(function()
    if state.gen == gen and state.rundir then
      update()
    end
  end, 80)
end

-- ---------------------------------------------------------------- panel

local function actions()
  return {
    toggle = function()
      M.toggle()
      refresh()
    end,
    next = function()
      M.seek("+1")
      refresh()
    end,
    prev = function()
      M.seek("-1")
      refresh()
    end,
    faster = function()
      M.speed("-0.05")
      refresh()
    end,
    slower = function()
      M.speed("+0.05")
      refresh()
    end,
    restart = function()
      M.seek(tostring(read_number("idx", 0)))
      refresh()
    end,
    close = function()
      ui.close()
    end,
    stop = function()
      M.stop()
    end,
  }
end

-- Open (or focus) the transport panel for the running session.
function M.panel()
  if not state.rundir then
    state.rundir = cli_sync({ "rundir" })
  end
  if not state.rundir or (read_value("state") or "none") == "none" then
    notify("no session running", vim.log.levels.WARN)
    return
  end
  ui.open(actions(), config.win)
  update()
end

-- ---------------------------------------------------------------- commands

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  if vim.fn.hlexists(config.hl_group) == 0 then
    vim.api.nvim_set_hl(0, config.hl_group, { link = config.hl_link, default = true })
  end
end

function M.start(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()

  if config.filetypes then
    local ft = vim.bo[buf].filetype
    if not config.filetypes[ft] then
      notify("buffer filetype is '" .. (ft ~= "" and ft or "none") .. "', expected markdown", vim.log.levels.WARN)
      return
    end
  end

  if vim.fn.executable(config.cmd) == 0 then
    notify("'" .. config.cmd .. "' not found on PATH", vim.log.levels.ERROR)
    return
  end

  M.stop({ silent = true })
  state.gen = state.gen + 1

  -- Read the buffer as it is now, unsaved edits included, so the line numbers the CLI
  -- reports line up with what is on screen.
  -- Keep the real filename inside a temp directory, so the panel header names the
  -- document rather than a scratch path
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
  if name == "" then
    name = "buffer.md"
  end
  state.tmpdir = vim.fn.tempname()
  vim.fn.mkdir(state.tmpdir, "p")
  state.tmpfile = state.tmpdir .. "/" .. name
  vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), state.tmpfile)

  state.src_buf = buf
  state.src_win = vim.api.nvim_get_current_win()
  state.last_idx = nil
  state.lines, state.sizes, state.chunk = nil, nil, nil

  state.rundir = cli_sync({ "rundir" })
  if not state.rundir then
    notify("could not resolve the session directory", vim.log.levels.ERROR)
    return
  end

  local voice = opts.voice or config.voice
  local speed = opts.speed or config.speed
  -- -b starts the session detached and returns as soon as the daemon is up: no terminal,
  -- so the transport panel can be an ordinary buffer
  local args = { "-b", state.tmpfile }
  -- The CLI takes VOICE before SPEED positionally, so a speed alone still needs a voice
  if speed and not voice then
    voice = "alan"
  end
  if voice then
    table.insert(args, voice)
  end
  if speed then
    table.insert(args, tostring(speed))
  end

  ensure_hl()

  local errors = {}
  vim.fn.jobstart(vim.list_extend({ config.cmd }, args), {
    stderr_buffered = true,
    on_stderr = function(_, data)
      errors = data or {}
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          local msg = vim.trim(table.concat(errors, " "))
          notify(msg ~= "" and msg or ("'" .. config.cmd .. "' exited with " .. code), vim.log.levels.ERROR)
          M.stop({ keep_session = true })
          return
        end
        ui.open(actions(), config.win)
        start_timer()
      end)
    end,
  })
end

function M.stop(opts)
  opts = opts or {}
  state.gen = state.gen + 1
  stop_timer()
  clear_highlight()
  ui.close()

  if not opts.keep_session then
    cli({ "stop" })
  end

  if state.tmpdir then
    vim.fn.delete(state.tmpdir, "rf")
    state.tmpdir, state.tmpfile = nil, nil
  end
  state.lines, state.sizes, state.chunk, state.last_idx = nil, nil, nil, nil
end

function M.toggle()
  cli({ "toggle" })
end

function M.speed(arg)
  if not arg or arg == "" then
    notify("speed: " .. (read_value("speed") or "no session"))
    return
  end
  cli({ "speed", arg })
end

function M.seek(arg)
  state.last_idx = nil -- force the highlight to refresh
  cli({ "seek", arg })
end

-- Jump playback to a buffer line: the chunk that starts at or before it.
function M.jump(line)
  line = line or vim.api.nvim_win_get_cursor(0)[1]
  state.lines = state.lines or (state.rundir and load_line_map())
  if not state.lines then
    notify("no session running", vim.log.levels.WARN)
    return
  end
  local best, best_line = nil, -1
  for idx, src in pairs(state.lines) do
    if src <= line and src > best_line then
      best, best_line = idx, src
    end
  end
  if not best then
    notify("no chunk covers line " .. line, vim.log.levels.WARN)
    return
  end
  M.seek(tostring(best))
end

function M.status()
  local out = cli_sync({ "status" })
  notify(out and out ~= "" and out or "no session")
end

return M
