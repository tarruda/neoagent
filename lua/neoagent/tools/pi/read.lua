-- Model-facing contract adapted from Pi 3390bd9363 (MIT).
local M = {}

---@return Neoagent.Tool<unknown>
function M.new()
  local tool = require("neoagent.tools.read_file").new()
  tool.name = "read"
  tool.description =
    "Read the contents of a file. Supports text files and images (jpg, png, gif, webp, bmp). Images are sent as attachments. For text files, output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete."
  tool.prompt_snippet = "Read file contents"
  tool.prompt_guidelines = { "Use read to examine files instead of cat or sed" }
  return tool
end

return M
