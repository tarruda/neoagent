# HTTP regression recordings

These fixtures use the existing `neoagent-http-recording` version 1 format.
They drive the real HTTP decoder, API adapters, Authentication, catalogs and
Services without network access. Fixtures are YAML for readability and require
Mike Farah `yq` v4 on `PATH`. Run them with `make test-integration`.
Use `make test-http-live` for actual curl and incoming callback socket checks.

## Reproducing a reported provider issue

Start with the user's recordings under `~/.local/state/nvim/neoagent`
(or their configured `recording.directory`). Locate the relevant provider,
Session and time before reading bodies. Workspace exchanges live under
`workspaces/*/recordings/*/`; shared provider/authentication exchanges live
under `provider/recordings/<provider>/<date>/`. Do not copy the whole directory
into the repository or print entire conversations or credential material.

If the exchange is missing, ask the user to add this to their existing setup,
restart Neovim and reproduce the interaction:

```lua
recording = { enabled = true },
```

Ask for the provider, approximate time, Session and observed behavior. Let the
user perform login, refresh and model requests; regression development does
not authorize live account access. Start with the default rolling retention:
conversation requests usually contain the full history, so the last exchange
is normally sufficient. Only ask for `retention = "all"` when the last exchange
cannot explain the issue and earlier exchanges are needed, such as an earlier
retry or authentication step. The default `auto` format is suitable; use JSON
when exact JSON serialization matters or YAML cannot be parsed. Restore
previous recording settings afterward.

1. Inspect metadata and completion first. `neoagent.http_replay.read(path)`
   validates complete JSONL and `.partial.ndjson` files, and imports YAML with
   Mike Farah `yq` v4. A partial filename alone does not prove that
   the exchange is incomplete. Missing bodies/completions cannot be recovered.
   Invalid YAML needs inspection or a new JSON capture.
2. Create a minimal YAML fixture with synthetic content. Original recordings
   are local evidence, never reproduction or test inputs. Replace all prompts,
   assistant responses and thinking, tool arguments/results, code, attachments,
   and personal/account metadata with invented values. Do not retain excerpts
   or paraphrases of the personal conversation, even when relevant to the bug.
   Masking credentials or trimming history alone is insufficient.

   Preserve the behavior through protocol structure: request/response roles,
   field presence and types, headers/status, event order, stop reasons, and
   relationships between requests, responses and tool calls. Use consistent
   synthetic identifiers, paths and nonfunctional credentials throughout.
   When content triggers the failure, construct unrelated synthetic content
   with the same relevant syntax, encoding, size or malformed-byte pattern.
   Verify that it still reproduces the reported failure; do not fall back to
   the original conversation if the first adaptation fails.

   Authentication-classified response bodies are deliberately masked: use
   synthetic token envelopes, unsigned fake JWT claims, and nonfunctional
   signed storage URLs when needed. Never disable masking.
3. Rebuild response chunk/body byte counts after editing bytes. Lua string
   lengths count bytes, including UTF-8. Retain fragmentation when it matters.
   YAML native JSON values need serialization; their original whitespace and
   byte cuts cannot be recovered. Record that adaptation rather than claiming
   an exact byte capture. For byte-sensitive regressions, retain a string or
   base64 body instead of converting it to a native JSON value. The reader
   also accepts JSONL, so existing JSON recordings need no format migration.
4. Review the complete adaptation, assertions and provenance comments for
   personal content and credentials before adding them to the repository.
   A source recording hash can identify provenance without copying its private
   path or conversation. Leave originals unchanged.
5. Add a test through the real affected composition. Supply replay below the
   shared HTTP decoder, assert the product failure, and check consumption in
   teardown. Verify a bug regression fails against the unmodified code for
   the reported reason, then passes with the fix.

## Scenarios and matching

Define replay scenarios as Lua tables beside the test assertions.
`tests/helpers/http_replay.lua` accepts an exchange list with repo-relative
recording paths and exposes `scenario.url` as `https://api.test`, the origin
used by these fixtures:

```lua
local scenario = require("tests.helpers.http_replay").open({
  { path = "tests/recordings/openai/stream-01.yaml", headers_subset = true },
})
```

The YAML files contain recorded protocol data; matching rules and dependencies
belong to the tests. A direct
`require("neoagent.http_replay").new({ exchanges = { path } })` also works.
Pass the result as the existing internal `transport`/`http` dependency.

Requests match method, URL, headers and body. Header names and URL percent-hex
case are normalized. JSON objects and form fields compare structurally; arrays,
null, missing values and empty objects remain distinct. Multipart uploads ignore
the generated boundary while checking part order, part headers, field values,
and binary content byte for byte. A declared Content-Length is validated
before boundary normalization. `body_exact = true` requires identical body
bytes. There is no network fallback. Missing, extra
and mismatched requests fail locally; `assert_consumed()` also rejects unused
exchanges and errors caught by product retry logic. Diagnostics name exchange
IDs and differing dimensions without exposing actual request values.

File-upload fixtures retain native provider URLs because upload eligibility
depends on the final endpoint.

Most migrated fixtures retain selected request fields. Their tests declare
`headers_subset = true` and, where needed, `body_subset = true` explicitly.
Body projection checks every recorded top-level field, including nested values
in full. Keep credentials and meaningful request options among the checked
fields. Generated PKCE verifiers are omitted from the token fixture and checked
against the authorization challenge by the OAuth integration test. Do not use
projections to conceal a request mismatch.

Matching reserves the first unused matching exchange before yielding. Repeated
identical requests therefore consume entries in their declared sequence;
distinct concurrent requests can arrive independently. Each response chunk is
scheduled asynchronously with no delay by default. `timing = true` applies
recorded relative delays, but does not promise operating-system scheduling
precision or provide transcript/UI replay.

Concurrency uses explicit dependencies, not sleeps. An entry may declare:

```lua
{
  id = "watch",
  path = "tests/recordings/watch.yaml",
  after = { "load:request" },
  gates = { ["2"] = { "load:complete" } },
  finish_after = { "inspected" },
  open = true,
}
```

Signals are `<id>:request`, `<id>:chunk:<index>` and `<id>:complete`; a test can
also call `scenario.release("inspected")` after a product observation.
`open = true` keeps a subscription open until its caller cancels it. A recorded
cancellation is not injected into a new caller. Dependencies are bounded by
`timeout_ms` (default 5000); teardown calls `close()` to cancel outstanding
playback and then `assert_consumed()`. Historical decoder/model errors are
reproduced from the body by today's decoder, while network failures are replayed
as normalized transport failures. Old curl HTTP exit code 22 remains an HTTP
response, not a new process failure.

## Coverage and capture inventory

Every outbound API surface currently called by Neoagent is exercised below.
This is an endpoint/flow inventory, not a claim to cover every possible server
payload. Unit tests retain detailed malformed-response and lifecycle cases.
All credentials, browser inputs and account IDs in fixtures are synthetic.

| Surface | Integration coverage | Real capture status |
| --- | --- | --- |
| OpenAI Completions and Responses, tools, reasoning, usage, errors, cancellation | `openai_http_spec.lua` | Synthetic; real OpenAI inference needed. |
| OpenAI Platform and DeepSeek `/files`, metadata lookup and image references | `managed_file_conversations_spec.lua`, `recorded_file_uploads_spec.lua`, `file_upload_lifecycle_spec.lua` | DeepSeek upload and restart captured for Completions, Responses and Messages; the latter two also cover missing-file replacement and inline opt-out. OpenAI upload, lookup, missing-object, unauthorized lookup and credit-exhaustion responses are captured; successful OpenAI inference remains unverified. Both providers have real upload authentication failures. Local failure injection and malformed-response variants are synthetic. |
| Codex subscription file creation, blob PUT, finalization, inspection and image references | `managed_file_conversations_spec.lua`, `codex_file_uploads_spec.lua`, `file_upload_lifecycle_spec.lua` | Upload, reuse, restart and configuration opt-out captured with Luna, including Responses Lite and a complete image-producing tool loop. Real upload authentication failure captured. Signed-capability and classified error bodies use synthetic envelopes; polling and deletion scenarios remain synthetic. |
| Anthropic Messages, thinking signatures, tools/results, cache usage, cancellation | `anthropic_http_spec.lua`, `anthropic_provider_spec.lua` | Synthetic protocol cases plus authorized live Sonnet 5 first-prompt and signed-thinking continuation captures in `anthropic/sonnet-5/`. |
| Anthropic image upload, optimistic reuse, restart, stale-file repair, inline opt-out | `managed_file_conversations_spec.lua` | Authorized synthetic Sonnet 5 captures in `anthropic/managed-files/`; includes the real file-specific 404, inspection, replacement upload and resubmission. `anthropic/validation/` adds successful metadata lookup and an upload rejected with invalid credentials. |
| DeepSeek Completions; Z.AI metered and Coding Plan Completions | `openai_http_spec.lua`, `recorded_providers_spec.lua` | Minimized real DeepSeek and Coding Plan frames; ordinary Z.AI inference needed. |
| Alibaba Token Plan Completions and dedicated `sk-sp-` login | `recorded_providers_spec.lua` | Minimized real inference; synthetic credential. |
| OpenCode Go Completions, Responses and Messages routing, both credential headers, Session header | `recorded_providers_spec.lua` | Minimized real Completions; real Responses and Messages needed. |
| OpenAI `/models`, organization usage/completions and costs | `provider_management_spec.lua`, `provider_surfaces_spec.lua` | Synthetic success/reporting denial; successful real organization reports needed. |
| Anthropic paginated `/models`, organization messages usage and cost reports | Same two management suites | Synthetic; real catalog and reports needed. |
| DeepSeek `/models`, `/user/balance` | `provider_management_spec.lua`, `provider_surfaces_spec.lua` | Balance adapted from a real response; catalog remains synthetic. |
| Z.AI and Coding Plan `/models`, balance and quota/limit | `provider_management_spec.lua` | Synthetic adaptations; real management recordings exist locally for follow-up promotion. |
| OpenCode Go `/models`, `/usage` | `provider_surfaces_spec.lua` | Catalog adapted from a real response; usage remains synthetic. |
| Alibaba console callback and TokenPlanOverview gateway query | `alibaba_token_plan_auth_spec.lua`, `provider_management_spec.lua` | Synthetic JSON/form/multipart callbacks and query; real overview exists, real login capture needed. |
| Codex browser PKCE callback, pasted redirect, device code/pending/slow-down, code exchange, refresh rotation and concurrent resolution | `openai_codex_oauth_spec.lua`, `provider_surfaces_spec.lua` | Synthetic; real browser, manual and device flows plus refresh needed. Token bodies will remain masked. |
| Codex Responses, retry, usage headers and OAuth-wrapped inference | `openai_http_spec.lua`, `openai_codex_oauth_spec.lua`, `provider_surfaces_spec.lua`, `codex_file_uploads_spec.lua` | Uploaded-image inference adapted from a real capture. Retry and usage-header scenarios remain synthetic. |
| Codex `/codex/models` including conditional 304; wham usage, profiles/me, accounts/check, reset credits and consume | `codex_management_spec.lua`, `provider_surfaces_spec.lua` | Synthetic; local real wham usage exists. Other real endpoints needed; credit consumption must be a user-chosen account action. |
| llama.cpp anonymous/key probes, `/models`, load/unload, downloads, `/models/sse`, polling, catalog reload and multimodal Completions | `llama_http_spec.lua`, `provider_surfaces_spec.lua`, `recorded_providers_spec.lua` | Minimized real inference; router workflows captured from the former synthetic server. Real load/download/cancel flows needed. |
| Hugging Face model search and repository details with optional token | `provider_surfaces_spec.lua` | Synthetic; real public and authenticated queries needed. |

The fixtures below adapt selected frames or response structures from user
recordings and authorized implementation validation. Conversation text,
identities, tool content, credentials, balances,
and other account metadata were replaced with synthetic values. Relevant field
types, selected event order, and response shapes were preserved; byte counts
were rebuilt. These are minimized protocol examples, not complete real
conversations. Source file hashes identify their provenance:

| Fixture | Original recording SHA-256 |
| --- | --- |
| [`real/alibaba-token-plan.yaml`](real/alibaba-token-plan.yaml) | `268c78d92092132ef44ef1cb2cdabb61d61f64f2d65c39cde2f7fd12f85874db` |
| [`real/deepseek.yaml`](real/deepseek.yaml) | `b51f504bd3a29335050e5f5df024e34e86b65c8c3f5598a088bea1e4c671940d` |
| [`deepseek/files/upload.yaml`](deepseek/files/upload.yaml) | `072ddf44c08f5056c19b86cffba8d352f8841c491f5a0db31e4f0b61626271b5` |
| [`deepseek/files/conversation.yaml`](deepseek/files/conversation.yaml) | `53e254aa4a3ee1955c93cb3cbe21c4b9cb1da69d70865bb6c5b090cc1c057032` |
| [`openai-codex/files/conversation.yaml`](openai-codex/files/conversation.yaml) | `d76d20a019b8415ca97422c3554484d535e951367287b97f759e979268ca55c1` |
| [`real/llama.cpp.yaml`](real/llama.cpp.yaml) | `2a4bbb2446ef9b1ce49637d1bc48b6210de57cddb2665f0d3e74c51b5e1a9834` |
| [`real/opencode-go.yaml`](real/opencode-go.yaml) | `0514eb4d892ba09e45e13027620436ecff7bd8410af058a11f25c00b4cbb78ec` |
| [`real/zai-coding-plan.yaml`](real/zai-coding-plan.yaml) | `f6db25a27b2a167a2d27b2d5c5cfb5519c2eab520bcaf7fe8c9cf4956750b43c` |
| [`providers/management-02.yaml`](providers/management-02.yaml) | `a34c98f253bf912178695881b56bf75c09925b305c8cab222f652496088cdc77` |
| [`opencode-go/management-01.yaml`](opencode-go/management-01.yaml) | `cbc3b82891cb3392d1cf7f2fa5c64fb2525c88a16058d05b10d8690ac1e02ae2` |

The `managed-files/` directories under `openai-codex`, `deepseek`, and `openai`
contain authorized synthetic-image validation captures from 2026-09-08.
Each YAML identifies its source hash. These preserve upload, inference, restart
reuse, and Codex's upload opt-out paths through the actual HTTP decoder.
All credential and remote identities are replaced; encrypted reasoning is
replaced consistently across responses and subsequent requests, and response
chunks are reserialized. Codex's classified capability bodies are reconstructed
with nonfunctional URLs. The OpenAI capture covers a successful Files upload
followed by the account's credit-exhaustion response; it does not establish
successful inference with the uploaded image. OpenAI success and stale-reference
repair scenarios in `openai/files/` remain synthetic.

The 2026-09-09 validation adds `openai-codex/codex-lite/` and
`openai-codex/tool-loop/`, plus `deepseek/deepseek-responses/` and
`deepseek/deepseek-anthropic/`. These conversations use generated image content
from the outset. The tool-loop replay runs a headless Agent with durable
credentials and Session storage. It verifies publication after commit, stores
and uploads the tool's image, then restarts the Agent and Session to reuse the
remote image. DeepSeek's missing-file captures preserve its HTTP 400
`invalid_request_error` response; negative tests change individual fields to
ensure unrelated inspection failures cannot trigger replacement uploads.

The `validation/` directories contain captured upload authentication failures
and OpenAI/Anthropic metadata lookups. Invalid credentials were supplied only
to isolated validation requests. `file_upload_lifecycle_spec.lua` also uses successful real
upload responses with deterministic cancellation, timeout, producer replacement
and uncertain local cache publication. Those faults are injected locally;
they are not claims about observed server failures. The combined suite still
uses synthetic malformed-response tests. Neither line coverage nor replaying a
real response establishes live validation of every upload failure path.

Original user files are unchanged. Other fixtures are synthetic scenarios,
including adaptations of the former HTTP integration servers. The final cleanup
response in `llama/scenario-3-cleanup.yaml` is a synthetic empty object: its
original synthetic-server capture ended before that response was retained.
Repeated identical polling snapshots were trimmed; explicit dependencies in
the tests preserve the observations each regression requires.

The two DeepSeek file adaptations preserve the multipart fields, file metadata
envelope, tool-image references, and selected reasoning/text/usage stream
shapes from a successful upload and its following inference. A synthetic
one-pixel PNG replaces the attachment; all conversation content and metadata
are invented. `deepseek/files/inspect-missing.yaml` adapts the later real
missing-object response. The remaining `deepseek/files/` scenarios extend those shapes with
synthetic reuse, verification, expiry, deletion, and failure exchanges.
All `openai/files/` fixtures are synthetic. These scenarios replay durable
Sessions through the provider runtime and real Authentication/HTTP decoding;
they do not claim live verification of every lifecycle path. Their object
lifetimes use a fixed test clock, independent of the capture date. Chunk
boundaries and timings are synthetic.

The Codex file backend follows the official client's file-creation, blob PUT,
and finalization protocol. Authorized validation confirmed inference with
`input_image.file_id`, warm reuse, and reuse after reopening a durable Session.
`openai-codex/files/conversation.yaml` preserves selected event fields and the
event order from that generated-image inference, with invented conversation
content and identifiers. The other inference fixtures extend those frames.
Creation, finalization, and inspection responses carry signed capabilities and
are masked by Authentication during recording; their fixtures are synthetic
envelopes based on the client source and observed field shapes, including the
null MIME type returned by inspection. Blob upload bytes remain recorded;
credentials and signed URL parameters are masked. No signed URL enters the
remote-object cache. Live validation does not establish an object retention
period or verify the synthetic failure and deletion scenarios.

To fill the remaining real-capture gaps, use the corresponding provider in a
short conversation (include a tool turn or cancellation if relevant), refresh
its Provider Shell/catalog, or perform the listed login flow interactively.
For llama.cpp, separately load/unload and download/cancel a model. For Hugging
Face, search and inspect a model through the download dialog. Capture only
account actions the user actually wants; existing synthetic coverage does not
require spending credits or changing subscriptions.
