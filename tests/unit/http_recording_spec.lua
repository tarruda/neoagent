local async = require("neoagent.async")
local config = require("neoagent.config")
local fs = require("neoagent.fs")

local function tempdir()
  local path = vim.fn.tempname()
  assert.are.equal(1, vim.fn.mkdir(path, "p"))
  return assert(vim.uv.fs_realpath(path))
end

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

local function files(root, suffix)
  local result = {}
  for _, path in ipairs(vim.fn.globpath(root, "**/*", false, true)) do
    if vim.uv.fs_stat(path) and path:sub(-#suffix) == suffix then
      result[#result + 1] = path
    end
  end
  table.sort(result)
  return result
end

local function records(path)
  local result = {}
  for line in assert(fs.read(path)):gmatch("[^\n]+") do
    result[#result + 1] = vim.json.decode(line)
  end
  return result
end

local function transport(chunks, response)
  return {
    request = function(opts)
      return async.run(function()
        for _, chunk in ipairs(chunks or {}) do
          if opts.on_chunk then opts.on_chunk(chunk) end
        end
        return response or {
          ok = true,
          response = {
            status = 200,
            headers = { ["content-type"] = "text/event-stream" },
          },
        }
      end, { on_done = opts.on_done, error_kind = "transport" })
    end,
    fetch = function(opts)
      return async.run(function()
        return response or {
          ok = true,
          status = 200,
          body = table.concat(chunks or {}),
        }
      end, { on_done = opts.on_done, error_kind = "transport" })
    end,
  }
end

describe("neoagent HTTP recording", function()
  local directories = {}

  after_each(function()
    config._reset()
    for _, path in ipairs(directories) do vim.fn.delete(path, "rf") end
    directories = {}
  end)

  it("validates an explicit, disabled-by-default recording configuration", function()
    local defaults = config.resolve({ default_registry = false })
    assert.is_false(defaults.recording.enabled)
    assert.are.equal("auto", defaults.recording.format)
    assert.are.equal("rolling", defaults.recording.retention)
    assert.matches("/neoagent$",
      defaults.recording.directory)

    local configured = config.resolve({
      default_registry = false,
      recording = {
        enabled = true,
        format = "json",
        retention = "all",
      },
    })
    assert.is_true(configured.recording.enabled)
    assert.are.equal("json", configured.recording.format)
    assert.are.equal("all", configured.recording.retention)

    assert.has_error(function()
      config.resolve({ default_registry = false,
        recording = { enabled = true, format = "toml" } })
    end, "recording.format must be auto, yaml, or json")
    assert.has_error(function()
      config.resolve({ default_registry = false,
        recording = { enabled = true, extra = true } })
    end, "unsupported recording setting: extra")
    assert.has_error(function()
      config.resolve({ default_registry = false,
        recording = { enabled = true, retention = "forever" } })
    end, "recording.retention must be rolling or all")
  end)

  it("selects one format for the recorder lifecycle", function()
    local recording = require("neoagent.http_recording")
    assert.is_nil(recording.new())
    assert.is_nil(recording.new({ config = { enabled = false } }))

    local json = assert(recording.new({
      config = { enabled = true, format = "json" },
      yq = { available = function() error("must not probe") end },
    }))
    assert.are.equal("json", json:format())
    assert.is_true(json:destroy())
    assert.is_false(json:destroy())

    local fallback = assert(recording.new({
      config = { enabled = true, format = "auto" },
      yq = { available = function() return false end },
    }))
    assert.are.equal("json", fallback:format())
    fallback:destroy()

    local unavailable, err = recording.new({
      config = { enabled = true, format = "yaml" },
      yq = { available = function() error("probe failed") end },
    })
    assert.is_nil(unavailable)
    assert.matches("compatible yq v4 is unavailable", err.message)
    assert.has_error(function()
      recording.new({ config = { enabled = true, format = "xml" } })
    end, "recording format must be auto, yaml, or json")
    assert.has_error(function()
      recording.new({ config = {
        enabled = true, format = "json", retention = "forever",
      } })
    end, "recording retention must be rolling or all")
  end)

  it("stores Workspace and provider-owned traffic separately", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = directory,
      now = function() return 1788363492417 end,
    }))
    local model = recording:transport(transport({ "model response" }), {
      workspace = workspace,
      provider = "example",
      model = "test-model",
      origin = "model",
      session_id = "session-42",
    })
    assert.is_true(wait(model.fetch({ request = {
      url = "https://example.test/model",
    } })).ok)

    local original = vim.fn.getcwd()
    local ok, err = xpcall(function()
      vim.cmd.cd(vim.fn.fnameescape(directory))
      local catalog = recording:transport(transport({ "catalog response" }), {
        provider = "example",
        origin = "catalog",
      })
      assert.is_true(wait(catalog.fetch({ request = {
        url = "https://example.test/models",
      } })).ok)
    end, debug.traceback)
    vim.cmd.cd(vim.fn.fnameescape(original))
    if not ok then error(err, 0) end
    recording:destroy()

    local workspace_directory = fs.join(
      directory, "workspaces", vim.fs.basename(workspace)
        .. "-" .. vim.fn.sha256(workspace))
    local workspace_paths = vim.fn.globpath(fs.join(
      workspace_directory, "recordings", "2026-09-02-session-42"),
      "*.jsonl", false, true)
    local provider_paths = vim.fn.globpath(fs.join(
      directory, "provider", "recordings", "example", "2026-09-02"),
      "*.jsonl", false, true)
    assert.are.equal(1, #workspace_paths)
    assert.are.equal(1, #provider_paths)
    for _, path in ipairs({
      fs.join(directory, "workspaces"),
      workspace_directory,
      fs.join(workspace_directory, "recordings"),
      fs.join(directory, "provider"),
      fs.join(directory, "provider", "recordings"),
      fs.join(directory, "provider", "recordings", "example"),
    }) do
      assert.are.equal(448, require("bit").band(
        assert(vim.uv.fs_stat(path)).mode, 511))
    end
    local index_content = assert(fs.read(
      fs.join(workspace_directory, "workspace.json")))
    assert.are.equal(workspace, vim.json.decode(index_content).root)
    assert.are.equal(workspace, records(workspace_paths[1])[1].workspace.root)
    assert.is_nil(records(provider_paths[1])[1].workspace)
  end)

  it("keeps recording when the Workspace index cannot be published", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local reports = {}
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = directory,
      report = function(message) reports[#reports + 1] = message end,
    }))
    local original_replace = fs.atomic_replace
    fs.atomic_replace = function(path, ...)
      if path:sub(-#"workspace.json") == "workspace.json" then
        return nil, "index unavailable"
      end
      return original_replace(path, ...)
    end
    local ok, err = xpcall(function()
      local http = recording:transport(transport({ "response" }), {
        workspace = workspace,
        provider = "example",
        origin = "model",
      })
      assert.is_true(wait(http.fetch({ request = {
        url = "https://example.test/model",
      } })).ok)
    end, debug.traceback)
    fs.atomic_replace = original_replace
    recording:destroy()
    if not ok then error(err, 0) end

    assert.are.equal(1, #files(directory, ".jsonl"))
    assert.matches("failed to write Workspace recording index", reports[1])
  end)

  it("uses one compatible yq process after closing an exchange", function()
    if jit.os == "Windows" then return end
    local directory, workspace, bin = tempdir(), tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    directories[#directories + 1] = bin
    local yq = fs.join(bin, "yq")
    assert(fs.atomic_replace(yq, [[#!/usr/bin/env python3
import pathlib
import sys

if "--version" in sys.argv:
    print("yq (https://github.com/mikefarah/yq/) version v4.45.1")
else:
    for line in pathlib.Path(sys.argv[-1]).read_text().splitlines():
        print("---")
        print(line)
]], { mode = 448 }))
    local original_path = vim.env.PATH
    vim.env.PATH = bin .. ":" .. (original_path or "")
    local ok, err = xpcall(function()
      local recording = assert(require("neoagent.http_recording").new({
        config = { enabled = true, format = "auto" },
        directory = directory,
      }))
      assert.are.equal("yaml", recording:format())
      local http = recording:transport(transport({ "body" }), {
        workspace = workspace,
      })
      assert.is_true(wait(http.fetch({ request = {
        url = "https://example.test/yaml",
      } })).ok)
      assert(vim.wait(3000,
        function() return #files(directory, ".yaml") == 1 end))
      recording:destroy()
      assert.matches("^%-%-%-", assert(fs.read(
        files(directory, ".yaml")[1])))
      assert.are.equal(0, #files(directory, ".partial.ndjson"))
    end, debug.traceback)
    vim.env.PATH = original_path
    if not ok then error(err, 0) end
  end)

  it("renders JSON bodies with legal escapes as native YAML", function()
    if vim.fn.executable("yq") ~= 1 then return end
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local recording = require("neoagent.http_recording").new({
      config = { enabled = true, format = "yaml", retention = "all" },
      directory = directory,
    })
    if not recording then return end
    local http = recording:transport(transport(nil, {
      ok = true,
      status = 200,
      body = '{"link":"https:\\/\\/example.test\\/result",'
        .. '"result":{"text":"readable response"}}',
      headers = { ["Content-Type"] = "application/json" },
    }), {
      workspace = workspace,
      origin = "model",
      session_id = "session-readable",
    })
    assert.is_true(wait(http.fetch({ request = {
      url = "https://example.test/yaml",
      headers = { ["Content-Type"] = "application/json" },
      body = '{"callback":"https:\\/\\/example.test\\/done",'
        .. '"model":"readable","messages":[{"role":"user"}]}',
    } })).ok)
    local malformed = recording:transport(transport(nil, {
      ok = true,
      status = 200,
      body = "{invalid response",
      headers = { ["Content-Type"] = "application/json" },
    }), {
      workspace = workspace,
      origin = "model",
      session_id = "session-readable",
    })
    assert.is_true(wait(malformed.fetch({ request = {
      url = "https://example.test/malformed",
      headers = { ["Content-Type"] = "application/json" },
      body = "{invalid request",
    } })).ok)
    assert(vim.wait(3000,
      function() return #files(directory, ".yaml") == 2 end))
    recording:destroy()

    local path, malformed_path
    for _, candidate in ipairs(files(directory, ".yaml")) do
      local content = assert(fs.read(candidate))
      if content:find("model: readable", 1, true) then
        path = candidate
      else
        malformed_path = candidate
      end
    end
    assert.is_truthy(path)
    assert.is_truthy(malformed_path)
    local request_type = vim.system({
      "yq", "eval-all",
      'select(.type == "exchange") | .request.body | type', path,
    }, { text = true }):wait()
    local response_type = vim.system({
      "yq", "eval-all",
      'select(.type == "response_body") | .body | type', path,
    }, { text = true }):wait()
    assert.are.equal(0, request_type.code)
    assert.are.equal(0, response_type.code)
    assert.are.equal("!!map", vim.trim(request_type.stdout))
    assert.are.equal("!!map", vim.trim(response_type.stdout))
    local content = assert(fs.read(path))
    assert.matches("body:%s*\n%s+callback: https://example%.test/done",
      content)
    assert.matches("%s+model: readable", content)
    assert.matches("%s+result:%s*\n%s+text: readable response", content)
    assert.matches("%s+link: https://example%.test/result", content)
    local malformed_type = vim.system({
      "yq", "eval-all",
      'select(.type == "exchange") | .request.body | type', malformed_path,
    }, { text = true }):wait()
    assert.are.equal(0, malformed_type.code)
    assert.are.equal("!!str", vim.trim(malformed_type.stdout))
  end)

  it("writes one Session-linked exchange with exact model bodies", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = directory,
      now = function() return 1788363492417 end,
      hrtime = (function()
        local value = 9000000000
        return function() value = value + 1000 return value end
      end)(),
    }))
    local response_chunks = {
      "data: {\"type\":\"start\",",
      "\"access_token\":\"response-body-secret\","
        .. "\"echo\":\"ordinary output\"}\n\n",
    }
    local request_body = vim.json.encode({
      model = "qwen-3.8-flash",
      api_key = "body-content-secret",
      echoed_key = "body-content-secret",
      empty_token = "",
      messages = { {
        role = "user",
        content = "Bearer user-supplied-content",
      } },
      image = { type = "base64", media_type = "image/png",
        data = "image-content" },
      inlineData = { mimeType = "image/png", data = "google-content" },
      bedrock = { source = { bytes = "bedrock-content" } },
      file = { file_data = "file-content" },
      download = "https://assets.test/file"
        .. "?X-Amz-Signature=body-url-content&size=small",
      mirror = "body-url-content",
    })
    local response_body = table.concat(response_chunks)
    local http = recording:transport(transport(response_chunks), {
      workspace = workspace,
      provider = "opencode-go",
      model = "qwen-3.8-flash",
      origin = "model",
      agent_id = "agent-7",
      session_id = "session-42",
    })

    local result = wait(http.request({ request = {
      url = "https://example.test/v1/messages"
        .. "?api_key=query-envelope-secret&mode=fast"
        .. "&X-Amz-Signature=signed-envelope-secret"
        .. "#token=fragment-envelope-secret",
      headers = {
        Authorization = "Bearer header-envelope-secret",
        ["Content-Type"] = "application/json",
        ["X-Custom-Secret"] = "custom-envelope-secret",
        ["X-Debug-Mode"] = "streaming",
        ["X-Echo"] = "header-envelope-secret",
        ["X-Body-Echo"] = "body-content-secret",
        ["X-Url-Echo"] = "query-envelope-secret",
        ["X-Empty-Token"] = "",
        ["Z-Trace"] = "last",
        ["A-Trace"] = "first",
        Link = "<https://assets.test/file?token=header-url-envelope-secret>"
          .. "; rel=preload",
      },
      body = request_body,
      timeout_ms = 600000,
      max_response_bytes = 1048576,
    } }))
    assert.is_true(result.ok)
    recording:destroy()

    local paths = files(directory, ".jsonl")
    assert.are.equal(1, #paths)
    assert.matches("20260902T", vim.fs.basename(paths[1]))
    assert.matches("opencode%-go%-model%.jsonl$", paths[1])
    assert.are.equal(384, require("bit").band(
      assert(vim.uv.fs_stat(paths[1])).mode, 511))

    local content = assert(fs.read(paths[1]))
    for _, secret in ipairs({
      "query-envelope-secret", "header-envelope-secret",
      "custom-envelope-secret", "fragment-envelope-secret",
      "header-url-envelope-secret", "signed-envelope-secret",
    }) do
      assert.is_nil(content:find(secret, 1, true), secret)
    end
    local first_line = assert(content:match("([^\n]+)"))
    local first_header = assert(first_line:find('"A-Trace"', 1, true))
    local last_header = assert(first_line:find('"Z-Trace"', 1, true))
    assert.is_true(first_header < last_header)
    local parsed = records(paths[1])
    assert.are.equal("exchange", parsed[1].type)
    assert.are.equal(workspace, parsed[1].workspace.root)
    assert.are.equal("session-42", parsed[1].context.session_id)
    assert.are.equal("agent-7", parsed[1].context.agent_id)
    assert.are.equal(600000, parsed[1].request.timeout_ms)
    assert.are.equal(1048576, parsed[1].request.max_response_bytes)
    assert.are.equal("*", parsed[1].request.headers.Authorization)
    assert.are.equal("streaming", parsed[1].request.headers["X-Debug-Mode"])
    assert.are.equal("*", parsed[1].request.headers["X-Echo"])
    assert.are.equal("body-content-secret",
      parsed[1].request.headers["X-Body-Echo"])
    assert.are.equal("*", parsed[1].request.headers["X-Url-Echo"])
    assert.are.equal("", parsed[1].request.headers["X-Empty-Token"])
    assert.matches("token=%*", parsed[1].request.headers.Link)
    assert.matches("X%-Amz%-Signature=%*", parsed[1].request.url)
    assert.are.equal(request_body, parsed[1].request.body)
    assert.are.equal(#request_body, parsed[1].request.body_bytes)
    assert.are.equal("json", parsed[1].request.body_format)
    assert.is_nil(parsed[1].request.body_encoding)
    assert.is_nil(parsed[1].request.redacted)
    assert.are.equal("response_chunk", parsed[2].type)
    assert.are.equal("response_chunk", parsed[3].type)
    assert.are.equal("response_body", parsed[4].type)
    assert.are.equal(response_body, parsed[4].body)
    assert.are.equal(#response_body, parsed[4].bytes)
    assert.is_nil(parsed[4].body_format)
    assert.is_nil(parsed[4].body_encoding)
    assert.is_nil(parsed[4].redacted)
    assert.are.equal("response", parsed[5].type)
    assert.are.equal("complete", parsed[6].type)
    assert.is_true(parsed[6].ok)
    assert.is_true(parsed[2].at_us <= parsed[3].at_us)
    assert.are.equal(2, parsed[3].index)
    assert.are.equal(0, #files(directory, ".partial.ndjson"))
  end)

  it("uses sortable names and converts each closed staging file once", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local converted = {}
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "auto", retention = "all" },
      directory = directory,
      now = function() return 1788363492417 end,
      yq = {
        available = function() return true end,
        convert = function(path, done)
          converted[#converted + 1] = {
            path = path,
            content = assert(fs.read(path)),
          }
          done("schema: neoagent-http-recording\n", nil)
        end,
      },
    }))
    local http = recording:transport(transport({ "one" }), {
      workspace = workspace, provider = "example", origin = "catalog",
    })

    assert.is_true(wait(http.fetch({ request = {
      url = "https://example.test/models", method = "GET",
    } })).ok)
    assert.is_true(wait(http.fetch({ request = {
      url = "https://example.test/usage", method = "GET",
    } })).ok)
    assert(vim.wait(3000, function() return #files(directory, ".yaml") == 2 end))
    recording:destroy()

    local paths = files(directory, ".yaml")
    assert.are.equal(2, #paths)
    assert.is_true(vim.fs.basename(paths[1]) < vim.fs.basename(paths[2]))
    assert.are.equal(2, #converted)
    assert.matches('"type":"complete"', converted[1].content)
    assert.are.equal(0, #files(directory, ".partial.ndjson"))
  end)

  it("rolls finalized JSON exchanges by default", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = directory,
    }))
    local http = recording:transport(transport({ "response" }), {
      workspace = workspace,
      provider = "example",
      origin = "model",
      session_id = "rolling-json",
    })

    assert.is_true(wait(http.fetch({ request = {
      url = "https://example.test/first",
    } })).ok)
    assert.is_true(wait(http.fetch({ request = {
      url = "https://example.test/second",
    } })).ok)
    recording:destroy()

    local paths = files(directory, ".jsonl")
    assert.are.equal(1, #paths)
    assert.are.equal("https://example.test/second",
      records(paths[1])[1].request.url)
    assert.are.equal(0, #files(directory, ".partial.ndjson"))
  end)

  it("keeps the prior YAML until its rolling replacement publishes", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local conversions = {}
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "yaml" },
      directory = directory,
      yq = {
        available = function() return true end,
        convert = function(path, done)
          conversions[#conversions + 1] = { path = path, done = done }
        end,
      },
    }))
    local http = recording:transport(transport({ "response" }), {
      workspace = workspace,
      provider = "example",
      origin = "model",
      session_id = "rolling-yaml",
    })

    assert.is_true(wait(http.fetch({ request = {
      url = "https://example.test/first",
    } })).ok)
    assert.are.equal(1, #conversions)
    conversions[1].done("turn: first\n")
    local first_path = assert(files(directory, ".yaml")[1])
    local note_path = fs.join(vim.fs.dirname(first_path), "notes.txt")
    assert(fs.atomic_replace(note_path, "keep me\n", { mode = 384 }))

    assert.is_true(wait(http.fetch({ request = {
      url = "https://example.test/second",
    } })).ok)
    assert.are.equal(2, #conversions)
    assert.are.equal(1, #files(directory, ".yaml"))
    assert.are.equal(1, #files(directory, ".partial.ndjson"))
    assert.is_not_nil(vim.uv.fs_stat(first_path))

    conversions[2].done("turn: second\n")
    recording:destroy()
    local paths = files(directory, ".yaml")
    assert.are.equal(1, #paths)
    assert.are.equal("turn: second\n", assert(fs.read(paths[1])))
    assert.are.equal("keep me\n", assert(fs.read(note_path)))
    assert.is_nil(vim.uv.fs_stat(first_path))
    assert.are.equal(0, #files(directory, ".partial.ndjson"))
  end)

  it("waits for an active YAML publication during recorder shutdown", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local finish_conversion
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "yaml" },
      directory = directory,
      yq = {
        available = function() return true end,
        convert = function(_, done) finish_conversion = done end,
      },
    }))
    local http = recording:transport(transport({ "response" }), {
      workspace = workspace,
      provider = "example",
      origin = "model",
      session_id = "shutdown-conversion",
    })
    assert.is_true(wait(http.fetch({ request = {
      url = "https://example.test/shutdown-conversion",
    } })).ok)
    assert.is_function(finish_conversion)

    vim.schedule(function() finish_conversion("turn: final\n") end)
    assert.is_true(recording:destroy())
    assert.are.equal(1, #files(directory, ".yaml"))
    assert.are.equal(0, #files(directory, ".partial.ndjson"))
  end)

  it("keeps the prior final when a rolling replacement cannot publish", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local reports = {}
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = directory,
      report = function(message) reports[#reports + 1] = message end,
    }))
    local http = recording:transport(transport({ "response" }), {
      workspace = workspace,
      provider = "example",
      origin = "model",
      session_id = "rolling-publication-failure",
    })
    assert.is_true(wait(http.fetch({ request = {
      url = "https://example.test/first",
    } })).ok)
    local first_path = assert(files(directory, ".jsonl")[1])

    local original_rename = vim.uv.fs_rename
    local ok, err = xpcall(function()
      vim.uv.fs_rename = function(source, target, ...)
        if source:sub(-#".partial.ndjson") == ".partial.ndjson"
            and target:sub(-#".jsonl") == ".jsonl" then
          return nil, "rename failed", "EIO"
        end
        return original_rename(source, target, ...)
      end
      assert.is_true(wait(http.fetch({ request = {
        url = "https://example.test/second",
      } })).ok)
    end, debug.traceback)
    vim.uv.fs_rename = original_rename
    if not ok then error(err, 0) end
    recording:destroy()

    local paths = files(directory, ".jsonl")
    assert.are.equal(1, #paths)
    assert.are.equal(first_path, paths[1])
    assert.are.equal("https://example.test/first",
      records(paths[1])[1].request.url)
    assert.are.equal(1, #files(directory, ".partial.ndjson"))
    assert.matches("failed to publish recording", table.concat(reports, "\n"))
  end)

  it("keeps provider results when rolling cleanup fails", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local reports = {}
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = directory,
      report = function(message) reports[#reports + 1] = message end,
    }))
    local http = recording:transport(transport({ "response" }), {
      workspace = workspace,
      provider = "example",
      origin = "model",
      session_id = "rolling-failure",
    })
    assert.is_true(wait(http.fetch({ request = {
      url = "https://example.test/first",
    } })).ok)
    local first_path = assert(files(directory, ".jsonl")[1])

    local original_unlink = vim.uv.fs_unlink
    local original_scandir = vim.uv.fs_scandir
    local ok, err = xpcall(function()
      vim.uv.fs_unlink = function(path)
        if path == first_path then error("unlink exploded") end
        return original_unlink(path)
      end
      assert.is_true(wait(http.fetch({ request = {
        url = "https://example.test/unlink-failure",
      } })).ok)

      vim.uv.fs_unlink = original_unlink
      vim.uv.fs_scandir = function()
        error(string.rep("scan exploded ", 200))
      end
      assert.is_true(wait(http.fetch({ request = {
        url = "https://example.test/scan-exception",
      } })).ok)

      vim.uv.fs_scandir = function() return nil, "scan failed" end
      assert.is_true(wait(http.fetch({ request = {
        url = "https://example.test/scan-failure",
      } })).ok)
    end, debug.traceback)
    vim.uv.fs_unlink = original_unlink
    vim.uv.fs_scandir = original_scandir
    if not ok then error(err, 0) end

    assert.are.equal(4, #files(directory, ".jsonl"))
    assert.is_true(wait(http.fetch({ request = {
      url = "https://example.test/recovered",
    } })).ok)
    recording:destroy()
    local paths = files(directory, ".jsonl")
    assert.are.equal(1, #paths)
    assert.are.equal("https://example.test/recovered",
      records(paths[1])[1].request.url)
    local diagnostic = table.concat(reports, "\n")
    assert.matches("failed to remove a previous recording", diagnostic)
    assert.matches("failed to retain rolling recording", diagnostic)
    assert.matches("failed to list previous recordings", diagnostic)
    for _, message in ipairs(reports) do
      assert.is_true(#message <= #"neoagent: HTTP recording: " + 1024)
    end
  end)

  it("sanitizes classified credential bodies and preserves other bytes", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json", retention = "all" },
      directory = directory,
      context = function() return { workspace = workspace } end,
    }))
    local http = recording:transport(transport({ "safe response" }, {
      ok = true,
      status = 200,
      body = "safe response",
      headers = {
        ["content-type"] = "text/plain",
        ["set-cookie"] = "response-cookie",
        ["x-debug-mode"] = "device-flow",
        ["x-echo"] = "response-cookie",
        ["x-empty-token"] = "",
      },
    }), {}).with_context({
      origin = "authentication",
      auth_method = "oauth-test",
      credential_response_body = true,
    })

    local result = wait(http.fetch({ request = {
      url = "https://user:pass@example.test/token?mode=device#access_token=fragment-secret",
      headers = {
        ["Content-Type"] = "application/x-www-form-urlencoded",
        Cookie = "request-cookie",
      },
      body = "grant_type=authorization_code&client_id=oauth-client"
        .. "&code=oauth-code&refresh_token=&plain=value",
    } }))
    assert.is_true(result.ok)
    local empty_http = recording:transport(transport(nil, {
      ok = true,
      status = 204,
      body = "",
      headers = { ["x-empty-token"] = "" },
    }), {
      workspace = workspace,
      origin = "authentication",
      auth_method = "oauth-test",
      credential_response_body = true,
    })
    assert.is_true(wait(empty_http.fetch({ request = {
      url = "https://example.test/token/revoke",
      body = "",
    } })).ok)
    local json_http = recording:transport(transport(nil, {
      ok = true,
      status = 204,
      body = "",
    }), {
      workspace = workspace,
      origin = "authentication",
      auth_method = "oauth-test",
      credential_response_body = true,
    })
    assert.is_true(wait(json_http.fetch({ request = {
      url = "https://example.test/device",
      headers = { ["Content-Type"] = "application/json" },
      body = '{"clientSecret":"json-secret","metadata":{},"items":[]}',
    } })).ok)
    recording:destroy()

    local paths = files(directory, ".jsonl")
    assert.are.equal(3, #paths)
    local content = assert(fs.read(paths[1]))
    for _, secret in ipairs({
      "user:pass", "fragment-secret", "request-cookie",
      "response-cookie", "oauth-client", "oauth-code", "safe response",
    }) do
      assert.is_nil(content:find(secret, 1, true), secret)
    end
    local parsed = records(paths[1])
    assert.are.equal("authentication", parsed[1].context.origin)
    assert.are.equal("oauth-test", parsed[1].context.auth_method)
    assert.matches("mode=device", parsed[1].request.url, 1, true)
    assert.are.equal("*", parsed[3].body)
    assert.are.equal("device-flow", parsed[4].headers["x-debug-mode"])
    assert.are.equal("*", parsed[4].headers["x-echo"])
    assert.are.equal("", parsed[4].headers["x-empty-token"])
    assert.matches("client_id=%*", parsed[1].request.body)
    assert.matches("code=%*", parsed[1].request.body)
    assert.matches("refresh_token=", parsed[1].request.body)
    local empty_records = records(paths[2])
    assert.are.equal("", empty_records[1].request.body)
    assert.are.equal("", empty_records[3].body)
    assert.is_nil(empty_records[3].redacted)
    local json_records = records(paths[3])
    assert.are.equal('{"clientSecret":"*","items":[],"metadata":{}}',
      json_records[1].request.body)
    assert.are.equal("json", json_records[1].request.body_format)
    assert.is_nil(assert(fs.read(paths[3])):find(
      "json-secret", 1, true))

    local binary_directory = tempdir()
    directories[#directories + 1] = binary_directory
    local binary = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json", retention = "all" },
      directory = binary_directory,
    }))
    local binary_http = binary:transport(transport({ "bad\255bytes" }), {
      workspace = workspace,
    })
    assert.is_true(wait(binary_http.request({ request = {
      url = "https://example.test/binary",
    } })).ok)
    local opaque_http = binary:transport(transport(nil, {
      ok = true,
      status = 200,
      headers = { ["content-type"] = "application/octet-stream" },
      body = "valid-ascii-binary",
    }), { workspace = workspace })
    assert.is_true(wait(opaque_http.fetch({ request = {
      url = "https://example.test/opaque",
    } })).ok)
    binary:destroy()
    local binary_paths = files(binary_directory, ".jsonl")
    assert.are.equal(2, #binary_paths)
    local binary_records = records(binary_paths[1])
    assert.are.equal(vim.base64.encode("bad\255bytes"),
      binary_records[3].body)
    assert.are.equal("base64", binary_records[3].body_encoding)
    assert.is_nil(binary_records[3].redacted)
    local opaque_records = records(binary_paths[2])
    assert.are.equal("valid-ascii-binary", opaque_records[3].body)
    assert.is_nil(opaque_records[3].body_encoding)
    assert.is_nil(opaque_records[3].redacted)
  end)

  it("scrubs protocol envelopes while preserving ordinary response content", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local response_body = '{"token":"ordinary-response-token"}'
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json", retention = "all" },
      directory = directory,
    }))
    local http = recording:transport(transport(nil, {
      ok = true,
      status = 200,
      body = response_body,
      headers = {
        ["content-type"] = "application/json",
        ["set-cookie"] = "session=response-cookie; Path=/; HttpOnly",
        location = "https://example.test/redirect"
          .. "?access_token=response-location-secret&empty=",
        ["x-echo"] = "response-cookie",
      },
    }), {
      workspace = workspace,
      origin = "authentication",
    })
    local requests = {
      {
        url = "https://example.test/json?empty=&bare#fragment-secret",
        headers = {
          ["Content-Type"] = "application/json",
          ["X-Binary"] = "bad\255",
          ["X-Flag"] = false,
        },
        body = '{"custom_token":{"number":7,"flag":true,'
          .. '"none":null,"nested":["nested-secret"]},'
          .. '"callback":"https://callback.test/path?api_key=nested-url-secret"}',
      },
      {
        url = "https://example.test/empty-fragment#",
        body = "",
      },
      {
        url = "https://example.test/form",
        headers = {
          ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        body = "grant_type=client_credentials&orphan",
      },
      {
        url = "https://example.test/text",
        headers = { ["Content-Type"] = "text/plain" },
        body = "Bearer protocol-request-secret",
      },
      {
        url = "https://example.test/yaml",
        headers = { ["Content-Type"] = "application/yaml" },
        body = "name: ordinary",
      },
      {
        url = "https://example.test/javascript",
        headers = { ["Content-Type"] = "application/javascript" },
        body = "const value = 1",
      },
    }
    for _, request in ipairs(requests) do
      assert.is_true(wait(http.fetch({ request = request })).ok)
    end
    recording:destroy()

    local captured = {}
    for _, path in ipairs(files(directory, ".jsonl")) do
      local parsed = records(path)
      captured[parsed[1].request.url] = parsed
      assert.are.equal(response_body, parsed[3].body)
      assert.are.equal("json", parsed[3].body_format)
      assert.is_nil(parsed[3].redacted)
      assert.matches("access_token=%*", parsed[4].headers.location)
      assert.are.equal("*", parsed[4].headers["set-cookie"])
      assert.are.equal("*", parsed[4].headers["x-echo"])
    end
    assert.are.equal(6, vim.tbl_count(captured))
    local json = captured[
      "https://example.test/json?empty=&bare#*"]
    assert.is_truthy(json)
    assert.are.equal("*", json[1].request.headers["X-Binary"])
    assert.are.equal("false", json[1].request.headers["X-Flag"])
    assert.are.same({
      callback = "https://callback.test/path?api_key=*",
      custom_token = "*",
    }, vim.json.decode(json[1].request.body))
    assert.is_truthy(captured["https://example.test/empty-fragment#"])
    assert.are.equal("grant_type=client_credentials&orphan",
      captured["https://example.test/form"][1].request.body)
    assert.are.equal("Bearer *",
      captured["https://example.test/text"][1].request.body)
    assert.are.equal("name: ordinary",
      captured["https://example.test/yaml"][1].request.body)
    assert.are.equal("const value = 1",
      captured["https://example.test/javascript"][1].request.body)
  end)

  it("masks classified credential failures for buffered and streamed HTTP", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local failure = {
      ok = false,
      error = {
        kind = "auth",
        message = "OAuth token exchange failed",
        detail = '{"access_token":"detail-secret"}',
        code = "Bearer credential-code",
        status = 401,
        response = {
          status = 401,
          headers = { ["content-type"] = "application/json" },
          body = '{"access_token":"body-secret"}',
        },
      },
    }
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json", retention = "all" },
      directory = directory,
    }))
    local http = recording:transport(transport(nil, failure), {
      workspace = workspace,
      origin = "authentication",
      credential_response_body = true,
    })
    assert.is_false(wait(http.fetch({ request = {
      url = "https://example.test/buffered-token",
    } })).ok)
    assert.is_false(wait(http.request({ request = {
      url = "https://example.test/streamed-token",
    } })).ok)
    local no_response = recording:transport(transport(nil, {
      ok = false,
      error = { kind = "transport", message = "connection failed" },
    }), { workspace = workspace })
    assert.is_false(wait(no_response.fetch({ request = {
      url = "https://example.test/no-response",
    } })).ok)
    recording:destroy()

    local paths = files(directory, ".jsonl")
    assert.are.equal(3, #paths)
    for index = 1, 2 do
      local parsed = records(paths[index])
      assert.are.equal("*", parsed[3].body)
      assert.is_true(parsed[3].redacted)
      assert.are.equal("*", parsed[5].error.detail)
      assert.are.equal("Bearer *", parsed[5].error.code)
    end
    local absent = records(paths[3])
    assert.are.equal(0, absent[2].bytes)
    assert.is_false(absent[4].ok)
  end)

  it("records callback failures and keeps recording faults observational", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = directory,
    }))
    local http = recording:transport(transport({ "malformed-event" }), {
      workspace = workspace,
      provider = "broken",
      origin = "model",
    })
    local result = wait(http.request({
      request = { url = "https://example.test/stream" },
      on_chunk = function() error("decoder rejected malformed-event") end,
    }))
    assert.is_false(result.ok)
    recording:destroy()

    local parsed = records(files(directory, ".jsonl")[1])
    assert.are.equal("malformed-event", parsed[3].body)
    assert.is_false(parsed[5].ok)
    assert.matches("decoder rejected", parsed[5].error.message)

    local unavailable = tempdir()
    directories[#directories + 1] = unavailable
    local blocked = fs.join(unavailable, "recordings")
    assert(fs.atomic_replace(blocked, "ordinary file", { mode = 384 }))
    local reports = {}
    local observer = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = blocked,
      report = function(message) reports[#reports + 1] = message end,
    }))
    local unrecorded = observer:transport(transport({ "still works" }), {
      workspace = workspace,
    })
    assert.is_true(wait(unrecorded.fetch({ request = {
      url = "https://example.test/unrecorded",
    } })).ok)
    observer:destroy()
    assert.is_true(#reports > 0)
    assert.are.equal("ordinary file", assert(fs.read(blocked)))
  end)

  it("keeps provider results when a staging file cannot be opened", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local reports = {}
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = directory,
      report = function(message) reports[#reports + 1] = message end,
    }))
    local http = recording:transport(transport({ "still works" }), {
      workspace = workspace,
      provider = "example",
    })

    local original_open = fs.open_regular
    local ok, result = xpcall(function()
      fs.open_regular = function(path, ...)
        if path:sub(-#".partial.ndjson") == ".partial.ndjson" then
          return nil, "open failed"
        end
        return original_open(path, ...)
      end
      return wait(http.fetch({ request = {
        url = "https://example.test/staging-open-failure",
      } }))
    end, debug.traceback)
    fs.open_regular = original_open
    if not ok then error(result, 0) end
    recording:destroy()

    assert.is_true(result.ok)
    assert.are.equal(0, #files(directory, ".partial.ndjson"))
    assert.are.equal(0, #files(directory, ".jsonl"))
    local diagnostic = table.concat(reports, "\n")
    assert.matches("failed to open a recording", diagnostic)
  end)

  it("records synchronous transport failures before rethrowing them", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = directory,
    }))
    local http = recording:transport({
      fetch = function() error("transport start failed") end,
    }, { workspace = workspace, provider = "broken" })

    local ok, err = pcall(http.fetch, { request = {
      url = "https://example.test/synchronous-failure",
    } })
    assert.is_false(ok)
    assert.matches("transport start failed", err)
    recording:destroy()

    local paths = files(directory, ".jsonl")
    assert.are.equal(1, #paths)
    local parsed = records(paths[1])
    assert.are.equal("response_body", parsed[2].type)
    assert.are.equal("complete", parsed[4].type)
    assert.is_false(parsed[4].ok)
    assert.are.equal("transport", parsed[4].error.kind)
    assert.matches("transport start failed", parsed[4].error.message)
  end)

  it("records buffered HTTP failures and propagates cancellation", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json", retention = "all" },
      directory = directory,
    }))
    local failed = recording:transport(transport(nil, {
      ok = false,
      error = {
        kind = "transport",
        message = "HTTP 429 returned-secret",
        detail = '{"token":"returned-secret"}',
        status = 429,
        retryable = true,
        response = {
          status = 429,
          headers = {
            ["content-type"] = "application/json",
            ["set-cookie"] = "cookie-secret",
            ["x-body-echo"] = "returned-secret",
            link = "<https://assets.test/failure"
              .. "?signature=response-url-secret>; rel=related",
          },
          body = '{"token":"returned-secret"}',
        },
      },
    }), {
      workspace = workspace,
      provider = "example",
      origin = "provider-shell",
    })
    local failed_result = wait(failed.fetch({ request = {
      url = "https://example.test/fail",
    } }))
    assert.is_false(failed_result.ok)

    local cancelled_child = false
    local pending = recording:transport({
      fetch = function(opts)
        return async.run(function()
          async.await(function()
            return function() cancelled_child = true end
          end)
        end, { on_done = opts.on_done, error_kind = "transport" })
      end,
    }, { workspace = workspace, provider = "example" })
    local cancelled = pending.fetch({ request = {
      url = "https://example.test/pending",
    } })
    recording:destroy()
    cancelled:cancel()
    local cancelled_result = wait(cancelled)
    assert.is_false(cancelled_result.ok)
    assert.are.equal("cancelled", cancelled_result.error.kind)
    assert.is_true(cancelled_child)

    local paths = files(directory, ".jsonl")
    assert.are.equal(2, #paths)
    local failure_content = assert(fs.read(paths[1]))
    assert.is_truthy(failure_content:find("returned-secret", 1, true))
    assert.is_nil(failure_content:find("cookie-secret", 1, true))
    assert.is_nil(failure_content:find("response-url-secret", 1, true))
    local failure_records = records(paths[1])
    assert.are.equal('{"token":"returned-secret"}',
      failure_records[3].body)
    assert.are.equal(429, failure_records[4].status)
    assert.are.equal("*", failure_records[4].headers["set-cookie"])
    assert.are.equal("returned-secret",
      failure_records[4].headers["x-body-echo"])
    assert.matches("signature=%*", failure_records[4].headers.link)
    assert.are.equal(429, failure_records[5].error.status)
    assert.are.equal('{"token":"returned-secret"}',
      failure_records[5].error.detail)
    assert.is_true(failure_records[5].error.retryable)
    assert.are.equal("cancelled", records(paths[2])[4].error.kind)
  end)

  it("retains NDJSON when final YAML conversion fails", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local reports = {}
    local recording = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "yaml" },
      directory = directory,
      report = function(message) reports[#reports + 1] = message end,
      yq = {
        available = function() return true end,
        convert = function(_, done)
          done(nil, "conversion failed with leaked-content")
        end,
      },
    }))
    local http = recording:transport(transport({ "body" }), {
      workspace = workspace,
    })
    assert.is_true(wait(http.fetch({ request = {
      url = "https://example.test/failure",
    } })).ok)
    recording:destroy()

    assert.are.equal(0, #files(directory, ".yaml"))
    assert.are.equal(1, #files(directory, ".partial.ndjson"))
    assert.matches('"type":"complete"',
      assert(fs.read(files(directory, ".partial.ndjson")[1])))
    assert.matches("failed to convert", table.concat(reports, "\n"))
    assert.is_nil(table.concat(reports, "\n"):find(
      "leaked-content", 1, true))
  end)

  it("records unclassified built-in authentication responses exactly", function()
    local directory, state = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = state
    local configured = config.resolve({
      default_registry = false,
      auth = { path = fs.join(state, "auth.json") },
    })
    local recorder = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = directory,
    }))
    local response_body = vim.json.encode({
      data = {},
      token = "ordinary-response-content",
    })
    local base = transport(nil, {
      ok = true,
      status = 200,
      headers = { ["content-type"] = "application/json" },
      body = response_body,
    })
    local manager = require("neoagent.auth").configured(configured, {
      transport = recorder:transport(base),
    })

    local result = wait(manager:login("llama", {
      prompt = function(_, done)
        done.resolve("http://127.0.0.1:8080")
        return function() end
      end,
    }))
    assert.is_true(result.ok)
    recorder:destroy()

    local paths = files(directory, ".jsonl")
    assert.are.equal(1, #paths)
    assert.matches("/provider/recordings/llama/", paths[1])
    local parsed = records(paths[1])
    assert.is_nil(parsed[1].workspace)
    assert.are.equal("authentication", parsed[1].context.origin)
    assert.are.equal("llama", parsed[1].context.auth_method)
    assert.is_nil(parsed[1].context.session_id)
    assert.are.equal(response_body, parsed[3].body)
    assert.is_nil(parsed[3].redacted)
  end)

  it("links direct Agent model traffic to its Session", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local agent = require("neoagent.agent").new({
      name = "Recorded",
      default_registry = false,
      default_model = { provider = "local", model = "recorded" },
      providers = { ["local"] = {
        api = "recording-test",
        models = { recorded = { input = { "text" } } },
      } },
      _apis = {
        ["recording-test"] = function(resolved)
          return {
            api = "recording-test",
            provider = resolved.provider_id,
            id = resolved.model_id,
            input = { "text" },
            stream = function(_, opts)
              return resolved.transport.fetch({
                request = {
                  url = "https://example.test/model",
                  body = "{}",
                  headers = { ["Content-Type"] = "application/json" },
                },
                on_done = opts and opts.on_done,
              })
            end,
          }
        end,
      },
      persistence = { enabled = false },
      recording = {
        enabled = true,
        format = "json",
        directory = directory,
      },
      tools = {},
    }, {
      workspace = workspace,
      transport = transport({ "{\"ok\":true}" }),
    })
    assert(agent:prepare())
    local expected = agent:summary()

    assert.is_true(wait(agent:get_model():stream({})).ok)
    agent:destroy()

    local paths = files(directory, ".jsonl")
    assert.are.equal(1, #paths)
    local exchange = records(paths[1])[1]
    assert.are.equal(expected.session_id, exchange.context.session_id)
    assert.are.equal(expected.id, exchange.context.agent_id)
    assert.are.equal(workspace, exchange.workspace.root)
    assert.are.equal("local", exchange.context.provider)
    assert.are.equal("recorded", exchange.context.model)
  end)

  it("records setup-created Agents in the configured directory", function()
    local directory, workspace = tempdir(), tempdir()
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local fake_model = require("tests.helpers.fake_model")
    local neoagent = require("neoagent")
    local owner = neoagent._setup({
      default_registry = false,
      default_model = { provider = "configured", model = "recorded" },
      providers = { configured = {
        api = "recording-setup-test",
        models = { recorded = { input = { "text" } } },
      } },
      _apis = {
        ["recording-setup-test"] = function(resolved)
          return {
            api = resolved.api,
            provider = resolved.provider_id,
            id = resolved.model_id,
            input = { "text" },
            stream = function(_, opts)
              return async.run(function()
                local fetched = resolved.transport.fetch({ request = {
                  url = "https://example.test/configured",
                  headers = { ["Content-Type"] = "application/json" },
                  body = vim.json.encode({ messages = opts.messages }),
                } }):await()
                if not fetched.ok then return fetched end
                return fake_model.assistant({ {
                  type = "text", text = "configured response",
                } })
              end, { on_done = opts.on_done, error_kind = "model" })
            end,
          }
        end,
      },
      persistence = { enabled = false },
      recording = {
        enabled = true,
        format = "json",
        directory = directory,
      },
      workspace_trust = false,
      tools = {},
      agent_instructions = false,
      skills = false,
    }, {
      transport = transport(nil, {
        ok = true,
        status = 200,
        headers = { ["x-debug-mode"] = "configured" },
        body = "server response",
      }),
    })
    local draft = assert(owner:draft("neo", workspace))
    local result = wait(assert(draft:send("record from setup")))
    assert.is_true(result.ok)
    local expected = assert(owner:target_agent()):summary()
    owner:destroy()

    local paths = files(directory, ".jsonl")
    assert.are.equal(1, #paths)
    local parsed = records(paths[1])
    assert.are.equal(expected.id, parsed[1].context.agent_id)
    assert.are.equal(expected.session_id, parsed[1].context.session_id)
    assert.are.equal(workspace, parsed[1].workspace.root)
    assert.are.equal("configured", parsed[4].headers["x-debug-mode"])
  end)
end)
