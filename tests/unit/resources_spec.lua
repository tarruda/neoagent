local agents = require("neoagent.agents")
local fs = require("neoagent.fs")
local skills = require("neoagent.skills")

describe("neoagent contextual resources", function()
  local paths = {}

  after_each(function()
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
  end)

  local function directory(path)
    assert.are.equal(1, vim.fn.mkdir(path, "p"))
    return path
  end

  local function write(path, content)
    directory(vim.fs.dirname(path))
    assert(fs.write_all(path, content, "w"))
    return path
  end

  local function skill(root, folder, content)
    return write(vim.fs.joinpath(root, folder, "SKILL.md"), content)
  end

  it("loads global and nested AGENTS.md files in precedence order", function()
    local base = vim.fn.tempname()
    local repo = base .. "/repo"
    local nested = repo .. "/src/module"
    local global = base .. "/A&\"'.md"
    paths[1] = base
    directory(repo .. "/.git")
    directory(nested)
    write(base .. "/AGENTS.md", "outside repository")
    write(global, "global instructions")
    write(repo .. "/AGENTS.md", "repository instructions")
    write(repo .. "/src/AGENTS.md", "source instructions")
    write(nested .. "/AGENTS.md", "module instructions")
    local not_file = directory(base .. "/not-a-file")

    local result = agents.discover({
      cwd = nested,
      global_files = { global, not_file, global },
      project_filenames = { "AGENTS.md" },
    })
    assert.are.same({
      "global instructions",
      "repository instructions",
      "source instructions",
      "module instructions",
    }, vim.tbl_map(function(file) return file.content end, result.files))
    assert.are.equal(1, #result.diagnostics)
    assert.matches("not a file", result.diagnostics[1].message)

    local prompt = agents.format(result.files)
    assert.matches("ordered from broadest to most specific", prompt)
    assert.matches("A&amp;&quot;&apos;%.md", prompt)
    assert.is_nil(prompt:find("outside repository", 1, true))
    assert.are.equal("", agents.format({}))
    assert.has_error(function() agents.discover({}) end)
  end)

  it("reports AGENTS.md read failures and supports paths outside a repository", function()
    local root = vim.fn.tempname()
    local nested = root .. "/one/two"
    paths[1] = root
    local path = write(root .. "/AGENTS.md", "unreadable")
    directory(nested)
    local original = fs.read
    fs.read = function(candidate)
      if candidate == path then return nil, "denied" end
      return original(candidate)
    end
    local ok, result = pcall(agents.discover, {
      cwd = nested,
      global_files = { path },
      project_filenames = {},
    })
    fs.read = original
    assert(ok)
    assert.are.equal(0, #result.files)
    assert.matches("denied", result.diagnostics[1].message)

    local original_find = vim.fs.find
    vim.fs.find = function() return {} end
    local ancestors = fs.ancestors(nested)
    vim.fs.find = original_find
    assert.are.equal("/", ancestors[1])
    assert.are.equal(vim.uv.fs_realpath(nested), ancestors[#ancestors])
  end)

  it("discovers valid skills lazily with local precedence", function()
    local base = vim.fn.tempname()
    local repo = base .. "/repo"
    local nested = repo .. "/src"
    local shared = base .. "/shared"
    local personal = base .. "/personal"
    paths[1] = base
    directory(repo .. "/.git")
    directory(nested)
    skill(shared, "alpha", table.concat({
      "---", "name: alpha", "description: shared alpha", "---",
      "SHARED WORKFLOW MUST STAY ON DISK", "",
    }, "\n"))
    skill(personal, "alpha", table.concat({
      "---", "name: alpha", 'description: "personal & alpha"', "---", "Personal body", "",
    }, "\n"))
    skill(repo .. "/.agents/skills", "alpha", table.concat({
      "---", "name: alpha", "description: 'project alpha'", "---", "Project body", "",
    }, "\n"))
    skill(nested .. "/.agents/skills", "beta", table.concat({
      "---", "# comment", "name: beta", "description: >",
      "  inspect <code>", "  carefully", "---", "BETA BODY MUST STAY ON DISK", "",
    }, "\n"))
    skill(nested .. "/.agents/skills", "gamma", table.concat({
      "---", "name: gamma", "description: |", "  first line", "  second line",
      "---", "Gamma body", "",
    }, "\n"))
    skill(nested .. "/.agents/skills/beta", "ignored", table.concat({
      "---", "name: ignored", "description: nested beneath a skill", "---", "", "",
    }, "\n"))
    skill(personal, ".hidden", "invalid")
    skill(personal, "node_modules/ignored", "invalid")

    local non_directory = write(base .. "/skills-file", "not a directory")
    local result = skills.discover({
      cwd = nested,
      global_dirs = { shared, personal, non_directory },
      project_dirs = { ".agents/skills" },
    })
    assert.are.same({ "alpha", "beta", "gamma" },
      vim.tbl_map(function(item) return item.name end, result.skills))
    assert.are.equal("project alpha", result.skills[1].description)
    assert.are.equal("project", result.skills[1].source)
    assert.are.equal("inspect <code> carefully", result.skills[2].description)
    assert.are.equal("first line\nsecond line", result.skills[3].description)
    assert.are.equal(1, #result.diagnostics)

    local prompt = skills.format(result.skills)
    assert.matches("<available_skills>", prompt)
    assert.matches("inspect &lt;code&gt; carefully", prompt)
    assert.matches("Use read_file", prompt)
    assert.is_nil(prompt:find("BETA BODY MUST STAY ON DISK", 1, true))
    assert.is_nil(prompt:find("SHARED WORKFLOW MUST STAY ON DISK", 1, true))
    assert.are.equal("", skills.format(nil))
    assert.has_error(function() skills.discover({}) end)
  end)

  it("reports malformed and unreadable skills without hiding valid ones", function()
    local root = vim.fn.tempname()
    paths[1] = root
    directory(root)
    local valid = skill(root, "valid", table.concat({
      "---\r", "name: x\r", "description: one character name\r", "---\r", "Body\r", "",
    }, "\n"))
    skill(root, "frontmatter", "No frontmatter")
    skill(root, "missing-name", "---\ndescription: missing\n---\nBody\n")
    skill(root, "invalid-name", "---\nname: bad--name\ndescription: invalid\n---\nBody\n")
    skill(root, "invalid-json-name", '---\nname: "bad\\q"\ndescription: invalid\n---\nBody\n')
    skill(root, "missing-description", "---\nname: missing-description\n---\nBody\n")
    skill(root, "long-description", "---\nname: long-description\ndescription: "
      .. string.rep("x", 1025) .. "\n---\nBody\n")
    local unreadable = skill(root, "unreadable",
      "---\nname: unreadable\ndescription: denied\n---\nBody\n")

    local original = fs.read
    fs.read = function(path)
      if path == unreadable then return nil, "denied" end
      return original(path)
    end
    local ok, result = pcall(skills.discover, {
      cwd = root,
      global_dirs = { root },
      project_dirs = {},
    })
    fs.read = original
    assert(ok)
    assert.are.same({ "x" }, vim.tbl_map(function(item) return item.name end, result.skills))
    assert.are.equal(vim.uv.fs_realpath(valid), result.skills[1].path)
    assert.are.equal(7, #result.diagnostics)
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(item) return item.message end,
      result.diagnostics), "skill name is required"))
  end)

  it("adds interaction guidance for Codex response models", function()
    local prompt = require("neoagent.system_prompt").default({
      model = { api = "openai-codex-responses" },
      workspace = { cwd = "/workspace" },
      tools = {},
    })
    assert.matches("Share concise progress updates", prompt)
    assert.matches("commentary", prompt)
    assert.matches("final", prompt)
  end)

  it("deduplicates linked skill files and reports directory scan failures", function()
    local base = vim.fn.tempname()
    local root = base .. "/skills"
    local broken = base .. "/broken"
    paths[1] = base
    local path = skill(root, "actual",
      "---\nname: linked\ndescription: linked skill\n---\nBody\n")
    directory(root .. "/alias")
    assert(vim.uv.fs_symlink(path, root .. "/alias/SKILL.md"))
    assert(vim.uv.fs_symlink(root .. "/actual", root .. "/directory-link"))
    directory(broken)

    local original = vim.uv.fs_scandir
    local canonical = vim.uv.fs_realpath(broken)
    vim.uv.fs_scandir = function(directory)
      if directory == canonical then return nil, "denied" end
      return original(directory)
    end
    local ok, result = pcall(skills.discover, {
      cwd = base,
      global_dirs = { root, root, broken },
      project_dirs = {},
    })
    vim.uv.fs_scandir = original
    assert(ok)
    assert.are.same({ "linked" }, vim.tbl_map(function(item) return item.name end, result.skills))
    assert.are.equal(1, #result.diagnostics)
    assert.matches("failed to scan skills", result.diagnostics[1].message)
  end)
end)
