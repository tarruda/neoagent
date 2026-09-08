---@meta no-require

-- Plenary exposes this subset of Busted. Tests import luassert locally so
-- its callable table does not replace Lua's production assert declaration.

---@param name string
---@param callback fun()
function describe(name, callback) end

---@param name string
---@param callback fun()
function it(name, callback) end

---@param name string
---@param callback? fun()
function pending(name, callback) end

---@param callback fun()
function before_each(callback) end

---@param callback fun()
function after_each(callback) end

function clear() end
