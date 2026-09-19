local M = {}

-- Normalized Tool requests enforce this shared semantic limit before either
-- local or private-RPC execution.
M.MAX_REQUEST_BYTES = require("neoagent.tools.limits").MAX_REQUEST_BYTES
-- Shell snapshots are throttled to ten per second. These bounds cover the
-- complete default five-minute invocation even when both text and ANSI
-- display copies reach their per-update limits.
M.MAX_UPDATE_COUNT = 4096
M.MAX_UPDATE_BYTES = 64 * 1024 * 1024
M.MAX_ARTIFACT_BYTES = require("neoagent.tools.limits").MAX_ARTIFACT_BYTES
M.MAX_ARTIFACTS_BYTES = 16 * 1024 * 1024
M.MAX_ARTIFACT_CHUNK_BYTES = 256 * 1024
M.MAX_QUEUED_BYTES = M.MAX_ARTIFACTS_BYTES + (8 * 1024 * 1024)

return M
