-- Command surface for dictator.nvim. Loading this file is enough; setup() is optional.
if vim.g.loaded_dictator then
  return
end
vim.g.loaded_dictator = true

local function dictator()
  return require("dictator")
end

local command = vim.api.nvim_create_user_command

command("DictatorStart", function(opts)
  dictator().start({ voice = opts.fargs[1], speed = opts.fargs[2] })
end, { nargs = "*", desc = "Read the current markdown buffer aloud" })

command("DictatorStop", function()
  dictator().stop()
end, { desc = "Stop reading and close the playback split" })

command("DictatorToggle", function()
  dictator().toggle()
end, { desc = "Pause or resume playback" })

command("DictatorSpeed", function(opts)
  dictator().speed(opts.args)
end, { nargs = "?", desc = "Set playback speed: N, +N or -N (length scale, lower = faster)" })

command("DictatorSeek", function(opts)
  dictator().seek(opts.args)
end, { nargs = 1, desc = "Seek by chunk: N, +N or -N" })

command("DictatorJump", function(opts)
  dictator().jump(opts.count > 0 and opts.count or (tonumber(opts.args) or nil))
end, { nargs = "?", count = 0, desc = "Jump playback to a buffer line (default: cursor, or :89DictatorJump)" })

command("DictatorStatus", function()
  dictator().status()
end, { desc = "Show playback status" })
