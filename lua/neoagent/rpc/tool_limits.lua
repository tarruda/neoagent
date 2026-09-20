local M = {}

-- Each scalar or table in a prepared request needs at most this much
-- MessagePack framing in addition to its string bytes.
M.REQUEST_VALUE_OVERHEAD = 16

-- Shell snapshots are throttled to ten per second. These bounds cover the
-- complete default five-minute invocation even when both text and ANSI
-- display copies reach their per-update limits.
M.MAX_UPDATE_COUNT = 4096
M.MAX_UPDATE_BYTES = 64 * 1024 * 1024
M.MAX_ARTIFACT_BYTES = require("neoagent.tools.limits").MAX_ARTIFACT_BYTES
M.MAX_ARTIFACTS_BYTES = 16 * 1024 * 1024
M.MAX_ARTIFACT_CHUNK_BYTES = 256 * 1024

return M
