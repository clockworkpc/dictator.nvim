-- dictator.nvim - read the current markdown buffer aloud, following along in the buffer.
--
-- The heavy lifting lives in the `dictate` CLI: it chunks the markdown, synthesizes it
-- with Piper, and exposes a session as plain state files. This module opens the CLI's
-- TUI in a vertical split, polls that state, and highlights the source line being read.

local M = {}

local config = {
  cmd = "dictate", -- CLI on PATH, or an absolute path
  voice = nil, -- nil = the CLI default (alan)
  speed = nil, -- nil = the CLI default (0.7)
  split = "vsplit", -- how the TUI window is opened
  width = 52, -- columns for the TUI split
  filetypes = { markdown = true }, -- set to nil to allow any buffer
  follow = true, -- scroll the source window to keep the read line visible
  poll_ms = 150,
  hl_group = "DictatorLine",
  hl_link = "Visual", -- default highlight, only if DictatorLine is undefined
}

local state = {
  src_buf = nil, -- buffer being read
  src_win = nil, -- window showing it
  tui_buf = nil, -- terminal buffer running `dictate tui`
  tui_win = nil,
  timer = nil,
  rundir = nil,
  lines = nil, -- chunk index (0-based) -> source line
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

local function stop_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

local function tick()
  local session_state = read_value("state")
  if not session_state or session_state == "stopped" or session_state == "none" then
    vim.schedule(function()
      M.stop({ keep_window = true })
    end)
    return
  end

  local idx = tonumber(read_value("idx") or "")
  if not idx or idx == state.last_idx then
    if session_state == "done" then
      vim.schedule(function()
        M.stop({ keep_window = true })
      end)
    end
    return
  end
  state.last_idx = idx

  if not state.lines then
    state.lines = load_line_map()
  end
  local line = state.lines and state.lines[idx]
  if line and line > 0 then
    vim.schedule(function()
      highlight_line(line)
    end)
  end
end

local function start_timer()
  stop_timer()
  state.timer = vim.loop.new_timer()
  state.timer:start(200, config.poll_ms, tick)
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

  -- Read the buffer as it is now, unsaved edits included, so the line numbers the CLI
  -- reports line up with what is on screen.
  -- Keep the real filename inside a temp directory, so the TUI header names the
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
  state.lines = nil

  state.rundir = cli_sync({ "rundir" })
  if not state.rundir then
    notify("could not resolve the session directory", vim.log.levels.ERROR)
    return
  end

  local voice = opts.voice or config.voice
  local speed = opts.speed or config.speed
  local args = { config.cmd, state.tmpfile }
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

  vim.cmd(config.split)
  state.tui_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(state.tui_win, config.width)
  -- termopen takes over the *current* buffer. The split still shows the document, so
  -- give the window a scratch buffer first or the document buffer becomes the terminal.
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.tui_win, scratch)
  vim.fn.termopen(args, {
    on_exit = function()
      vim.schedule(function()
        M.stop({ keep_window = true })
      end)
    end,
  })
  state.tui_buf = vim.api.nvim_get_current_buf()
  vim.bo[state.tui_buf].buflisted = false
  vim.wo[state.tui_win].number = false
  vim.wo[state.tui_win].relativenumber = false
  vim.wo[state.tui_win].signcolumn = "no"
  vim.wo[state.tui_win].winfixwidth = true

  -- Hand focus back to the text being read
  if vim.api.nvim_win_is_valid(state.src_win) then
    vim.api.nvim_set_current_win(state.src_win)
  end

  start_timer()
end

function M.stop(opts)
  opts = opts or {}
  stop_timer()
  clear_highlight()

  if not opts.keep_session then
    cli({ "stop" })
  end

  if not opts.keep_window and state.tui_win and vim.api.nvim_win_is_valid(state.tui_win) then
    vim.api.nvim_win_close(state.tui_win, true)
  end
  if state.tmpdir then
    vim.fn.delete(state.tmpdir, "rf")
    state.tmpdir, state.tmpfile = nil, nil
  end
  state.tui_win, state.tui_buf = nil, nil
  state.lines, state.last_idx = nil, nil
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
  state.last_idx = nil -- force the highlight to refresh
  cli({ "seek", tostring(best) })
end

function M.status()
  local out = cli_sync({ "status" })
  notify(out and out ~= "" and out or "no session")
end

return M
