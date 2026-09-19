local M = {}

-- Normalized bundled Tool requests use this limit for both local and RPC
-- execution so selecting a backend cannot change accepted arguments.
M.MAX_REQUEST_BYTES = 16 * 1024 * 1024

-- Paths also appear in result text and metadata. Bound them before effects so
-- a normalized short target cannot produce an oversized response afterward.
M.MAX_PATH_BYTES = 32 * 1024

-- Image configuration and RPC publication share this one authoritative
-- attachment budget, so changing execution location cannot change validity.
M.MAX_ARTIFACT_BYTES = 8 * 1024 * 1024

return M
