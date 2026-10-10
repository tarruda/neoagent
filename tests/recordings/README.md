# HTTP regression recordings

Fixtures replay `neoagent-http-recording` version 1 through real HTTP decoding
and provider compositions without network access. Run `make test-integration`
with Mike Farah `yq` v4 on `PATH`. Curl and callback sockets belong in
`make test-http-live`.

## Reproducing a provider issue

Find the relevant provider, Session, and time under the user's recording root
(default `~/.local/state/nvim/neoagent`). Workspace exchanges are in
`workspaces/*/recordings/*/`; shared exchanges are in
`provider/recordings/<provider>/<date>/`. Read metadata before bodies. Never
copy whole directories or print private conversations and credentials.

If evidence is missing, ask the user to enable `recording = { enabled = true }`,
restart, and reproduce. Use rolling retention unless earlier exchanges matter;
use JSON when exact serialization matters or YAML fails. Restore prior settings
after capture. The user performs account actions; regression work does not
itself authorize live API access.

1. Read with `neoagent.http_replay.read(path)`. It accepts JSONL, partial NDJSON,
   and YAML through `yq`. A partial filename does not establish completeness;
   missing bodies cannot be recovered. Invalid YAML needs inspection or recapture.
2. Create a minimal fixture with invented prompts, responses, thinking, Tool
   arguments/results, attachments, paths, and account data. Originals are local
   evidence, never test inputs. Masking, trimming, excerpts, or paraphrasing
   private conversations is insufficient. Preserve protocol structure and any
   triggering syntax, encoding, size, or fragmentation using unrelated content.
   Use nonfunctional credentials and token envelopes; never disable masking.
3. Recompute byte counts after edits. YAML native JSON values lose original
   whitespace and byte cuts; use string or base64 bodies for byte-sensitive
   cases. Review fixtures, assertions, and comments for private material. Keep
   originals unchanged; hashes can record provenance without private paths.
4. Inject replay below the real HTTP decoder in the affected composition.
   Assert the product failure and fixture consumption. Verify the regression
   fails before the fix and passes afterward.

## Replay scenarios

Keep matching rules and dependencies beside assertions:

```lua
local scenario = require("tests.helpers.http_replay").open({
  { path = "tests/recordings/openai/stream-01.yaml", headers_subset = true },
})
```

Inject `scenario` through the existing internal `transport` or `http`
dependency. `scenario.url` is `https://api.test`. Direct replay also supports
`neoagent.http_replay.new({ exchanges = { path } })`. Upload fixtures retain
native provider URLs because eligibility depends on the endpoint.

Matching checks method, URL, headers, and body. Header names and URL percent-hex
case normalize; JSON objects and forms compare structurally. Arrays, null,
missing values, and empty objects stay distinct. Multipart matching ignores
boundary text but checks parts, order, headers, bytes, and Content-Length.
`body_exact = true` requires identical bytes. There is no network fallback.

Use `headers_subset` or `body_subset` only for intentionally partial fixtures.
Body subsets select top-level fields but compare their nested values fully.
Keep credentials and meaningful options checked; do not hide mismatches.
Generated PKCE verifiers are instead checked against the authorization challenge.

Repeated identical requests consume exchanges in order; distinct requests may
arrive concurrently. Chunks deliver asynchronously. `timing = true` uses recorded
delays without promising OS scheduling or UI replay. Coordinate with dependencies,
not sleeps:

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

Signals are `<id>:request`, `<id>:chunk:<index>`, and `<id>:complete`;
`scenario.release("inspected")` supplies a test signal. `open = true` waits for
caller cancellation; recorded cancellation is not injected. Dependencies use
`timeout_ms` (default 5000).

Teardown calls `close()` then `assert_consumed()`, which catches missing, extra,
mismatched, and unused exchanges even when product retries swallowed an error.
Diagnostics omit request values. Decoder and Model errors must arise from
response bodies; network failures replay as transport errors, while curl exit 22
replays an HTTP response.

## Capture inventory

All fixture content and credentials are synthetic. Adapted captures preserve
observed protocol behavior; purely synthetic cases are not live validation.
Tests under `tests/integration/` define the assertions.

| Provider/surface | Adapted captures | Remaining capture gaps |
| --- | --- | --- |
| OpenAI Platform | Upload, lookup, missing-file and authentication failures, credit exhaustion. | Successful inference, catalog, organization usage and cost reports. |
| Codex | Image upload/reuse/restart/opt-out, Responses Lite, Tool loop, upload denial. | Browser/device login, refresh, retry/usage headers, management, polling/deletion. |
| Anthropic | Sonnet 5 inference and signed thinking; image lifecycle, stale-file repair, lookup, upload denial. | Catalog and organization reports. |
| DeepSeek | Completions/Responses/Messages with images, replacement and opt-out; metadata DNS failure; upload denial; balance. | Catalog. |
| Z.AI | Coding Plan inference. | Metered inference and management. |
| Alibaba Token Plan | Inference. | Login and quota reporting. |
| OpenCode Go | Completions and catalog. | Responses, Messages, usage. |
| llama.cpp | Inference. | Router load/unload/download/cancel and reasoning-only continuation. |
| Hugging Face | None. | Public and authenticated search and repository inspection. |

Fill gaps only through account actions the user wants. Synthetic coverage does
not justify spending credits, logging in, or changing subscriptions.

Source hashes identify adapted fixture provenance:

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
