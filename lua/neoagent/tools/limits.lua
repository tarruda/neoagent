local M = {}

-- Prepared inputs bound string bytes and structure independently of encoding.
M.MAX_INPUT_BYTES = 16 * 1024 * 1024
M.MAX_INPUT_VALUES = 65536

-- Paths also appear in result text and metadata. Bound them before effects so
-- a normalized short target cannot produce an oversized response afterward.
M.MAX_PATH_BYTES = 32 * 1024

M.MAX_EDIT_INPUT_BYTES = 64 * 1024 * 1024

-- Patch preflight retains replacements for several files before publication.
-- Bound their source and replacement bytes together, independently of argv.
M.MAX_PATCH_PREPARATION_BYTES = 128 * 1024 * 1024

-- Complete patch results, including partial publication, must fit the RPC
-- response frame with room for its envelope. Enforced before any file effects.
M.MAX_PATCH_RESULT_BYTES = 768 * 1024

-- Image configuration and RPC publication share this one authoritative
-- attachment budget, so changing execution location cannot change validity.
M.MAX_ARTIFACT_BYTES = 8 * 1024 * 1024

return M
