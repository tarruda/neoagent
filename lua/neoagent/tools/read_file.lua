local async = require("neoagent.async")
local common = require("neoagent.tools.common")
local fs = require("neoagent.fs")
local truncate = require("neoagent.tools.truncate")

local MIME = {
  png = "image/png",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  bmp = "image/bmp",
}

local function detect(data)
  if data:sub(1, 8) == "\137PNG\r\n\26\n" then return MIME.png end
  if data:sub(1, 3) == "\255\216\255" then return MIME.jpeg end
  if data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then return MIME.gif end
  if data:sub(1, 2) == "BM" then return MIME.bmp end
  if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return MIME.webp end
end

local function image_result(data, mime, note)
  return {
    content = {
      { type = "text", text = note },
      { type = "image", data = vim.base64.encode(data), mimeType = mime },
    },
  }
end

local function run_magick(data, mime)
  local input = vim.fn.tempname()
  local extension = mime == MIME.jpeg and ".jpg" or ".png"
  local output = vim.fn.tempname() .. extension
  local function cleanup()
    vim.uv.fs_unlink(input)
    vim.uv.fs_unlink(output)
  end
  local ok, result = pcall(function()
    assert(fs.write_all(input, data, "w", 384))
    local identified = common.process({ "magick", "identify", "-format", "%w %h", input })
    if identified.code ~= 0 then error(identified.stderr) end
    local ow, oh = identified.stdout:match("(%d+)%s+(%d+)")
    local converted = common.process({ "magick", input .. "[0]", "-auto-orient", "-resize", "2000x2000>", output })
    if converted.code ~= 0 then error(converted.stderr) end
    local bytes = assert(fs.read(output))
    local transmitted_mime = extension == ".jpg" and MIME.jpeg or MIME.png
    if #vim.base64.encode(bytes) > 4.5 * 1024 * 1024 then
      vim.uv.fs_unlink(output)
      extension = ".jpg"
      output = vim.fn.tempname() .. extension
      local reduced = common.process({
        "magick", input .. "[0]", "-auto-orient", "-resize", "1600x1600>", "-quality", "80", output,
      })
      if reduced.code ~= 0 then error(reduced.stderr) end
      bytes = assert(fs.read(output))
      transmitted_mime = MIME.jpeg
    end
    local final_identified = common.process({ "magick", "identify", "-format", "%w %h", output })
    local tw, th = final_identified.stdout:match("(%d+)%s+(%d+)")
    local note = "Read image file [" .. transmitted_mime .. "]"
    if ow and oh and tw and th and (ow ~= tw or oh ~= th) then
      note = note .. string.format("\n[Resized from %sx%s to %sx%s; coordinate scale %.4f x %.4f]", ow, oh, tw, th, ow / tw, oh / th)
    end
    return image_result(bytes, transmitted_mime, note)
  end)
  cleanup()
  if not ok then
    return nil, result
  end
  return result
end

local function new()
  return {
    name = "read_file",
    description = "Read a text file or image from disk. Text is limited to 2,000 lines or 50 KiB; use offset and limit to continue.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Path to the file to read (relative or absolute)" },
        offset = { type = "number", description = "Line number to start reading from (1-indexed)" },
        limit = { type = "number", description = "Maximum number of lines to read" },
      },
      required = { "path" },
      additionalProperties = false,
    },
    execute = function(arguments, ctx)
      local path = common.require_string(arguments, "path")
      local offset = arguments.offset or 1
      local limit = arguments.limit
      if type(offset) ~= "number" or offset < 1 or offset % 1 ~= 0 then
        error("offset must be a positive integer")
      end
      if limit ~= nil and (type(limit) ~= "number" or limit < 1 or limit % 1 ~= 0) then
        error("limit must be a positive integer")
      end
      local data, err = fs.read(common.workspace(ctx):resolve(path))
      if not data then
        error("Could not read file " .. path .. ": " .. tostring(err))
      end
      local mime = detect(data)
      if mime then
        if vim.fn.executable("magick") == 1 and async.current() then
          local processed, process_err = run_magick(data, mime)
          if processed then return processed end
          return image_result(data, mime, "Read image file [" .. mime .. "]\n[ImageMagick resize failed: " .. tostring(process_err) .. "; sending original]")
        end
        local note = "Read image file [" .. mime .. "]"
        if vim.fn.executable("magick") ~= 1 then
          note = note .. "\n[ImageMagick is unavailable; sending original image]"
        end
        return image_result(data, mime, note)
      end

      local all = vim.split(data, "\n", { plain = true })
      if offset > #all then
        error(string.format("Offset %d is beyond end of file (%d lines total)", offset, #all))
      end
      local last = limit and math.min(#all, offset + limit - 1) or #all
      local selected = table.concat(vim.list_slice(all, offset, last), "\n")
      local shortened = truncate.head(selected)
      local text
      if shortened.firstLineExceedsLimit then
        text = string.format("[Line %d is %s, exceeds %s limit. Use shell to inspect it in chunks.]", offset, truncate.format_size(#all[offset]), truncate.format_size(truncate.MAX_BYTES))
      elseif shortened.truncated then
        local ending = offset + shortened.outputLines - 1
        text = shortened.content .. string.format("\n\n[Showing lines %d-%d of %d. Use offset=%d to continue.]", offset, ending, #all, ending + 1)
      elseif limit and last < #all then
        text = shortened.content .. string.format("\n\n[%d more lines in file. Use offset=%d to continue.]", #all - last, last + 1)
      else
        text = shortened.content
      end
      return { content = { { type = "text", text = text } }, details = { truncation = shortened } }
    end,
  }
end

local M = new()
M.new = new
M.detect_mime = detect
return M
