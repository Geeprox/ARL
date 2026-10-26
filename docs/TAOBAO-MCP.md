# Taobao desktop MCP integration

> 2026-10-10 更新：以下按日期保留既有搜索及限制记录。公开已知天猫链接的 ID/URL/标题页面流程现已实测，并新增 `taobao_get_product` 源码；37 项商品检查、77 项搜索/Mio 检查及实际面板 typecheck 通过。全量详情、SKU、购物车仍未核验，正式 App/Mio 新工具尚未安装。当前范围见 [公开商品读取和购物车设计](TAOBAO-PUBLIC-PRODUCT-CART-DESIGN.md) 及 [资格记录](TAOBAO-PUBLIC-PRODUCT-QUALIFICATION.json)。旧段落的“两工具/详情未核验”描述其记录时版本，不覆盖本更新。

ARL owns the official local connection. Mio obtains an authenticated internal
capability catalog and publishes separate named MCP tools. The existing travel14
and music6 descriptors are preserved. General navigation, clicks, raw RPC,
orders, addresses, payment and credential-management tools are not published.

## Qualified search candidate, 2026-10-08

The installed official app is `com.taobao.desktop`, version/build `3.0.0`,
signing team `VJGTV94XY8`, at `/Applications/淘宝桌面版.app`. The production
probe checks the same-user running main process, Apple code signature and team,
strict static signature, exact reviewed executable and Info.plist digests, and
that process's ownership of the IPv4 listener `127.0.0.1:3654` before HTTP.
Only that exact version/build and Streamable HTTP qualify. Other distributions,
versions and CLI transports remain unqualified. The app.asar inspection and
public official guide establish selectors and the search route; they do not
change settings or grant permissions.

The actual live MCP catalog has 20 tools and requires truthful `sourceApp=ARL`.
It does not expose the older reference's dedicated `search_products` or product
and SKU query tools. The reviewed 3.0.0 catalog is pinned as a complete sorted
JSON descriptor set before the new search action can be published. Catalog drift
holds business calls. This is a fixed build qualification, not an inferred
minimum-version guarantee.

The catalog encoding sorts dictionary keys by UTF-8 bytes at every level,
preserves array order, and sorts descriptors by tool name. It does not use
Foundation's locale/numeric-aware sorted-key ordering. The complete catalog
digest is `b8cc2b59a0a1fadcc2fea9b24d2143a9d3a24f632488fb5538b6f1a0a67deec2`.

`taobao_search_products` accepts only a nonempty keyword (at most 64 characters)
and optional integer limit 1–3, default 3. The implementation uses only these
three official primitives internally:

- `navigate_to_url` with a generated `https://s.taobao.com/search?q=...` URL;
- `get_current_tab` to check the exact public search host, path and query;
- `read_page_content` scoped to fixed product-card title and price selectors.

Callers cannot supply URLs, selectors, sourceApp or arbitrary upstream actions.
Numeric bounds accept native integer and JSON number schema values, so the
literal 1–3 limit is enforced before dispatch; booleans and fractions are rejected.
Only initial rendering is polled with small fixed bounds; navigation is not
replayed. Before each scoped read and after the operation, the current search
URL is checked. Every successful read must report that search URL, zero offset,
zero remaining length, a matching UTF-16 total length, and boolean false
truncation. A second title read rejects card replacement during price reading.
An exact official missing-scope error can represent a missing optional price or
end of cards; generic, nested, outer, login and malformed failures still stop.

The response contains up to three ranked product cards. Title and simple visible
numeric price are projected; ambiguous or absent price stays null. Product ID,
URL, shop, details, SKU and other unavailable fields remain null. Page title,
account metadata, cookies, login state and raw tool results are not forwarded.
Every null product field is listed in sorted `unknown_fields`, including price
when the visible text does not establish one unambiguous numeric value.
A successful search is not evidence of SKU availability or purchase readiness.

## Detail and SKU limitation

The official `click_element` schema accepts `sourceApp` and text with optional
index. Two bounded diagnostic attempts with an exact twice-read product title
returned the official semantic error: “Script failed to execute, this normally
means an error was thrown. Check the renderer console for the error.” The code
field was absent and blocked/disabled were false. This establishes a renderer
script failure, not a proven authentication denial. No guessed coordinates,
indices, hidden RPC or permission bypass were used.

The public scan response supplies no stable product URL/ID/handle, and the
actual catalog has no `query_page` or structured extraction tool. Detail, SKU,
shop, reviews, cart read and cart write remain unbound in the 3.0.0 profile.
No shopping-history or account data is queried to fill these gaps.

## Protocol and failure handling

The client uses bounded ephemeral HTTP with no proxy, credentials, cookie store,
redirects or browser automation. The SSE parser ends an operation on its exact
JSON-RPC response rather than waiting for the server to close the stream. It
bounds bytes, events and IDs and handles fragmented UTF-8/CRLF/multiline frames.
Sessions are short-lived and never persisted or logged. Tool results pass the
same failure-marker checks at every bounded content, structuredContent or data
layer. A transport success alone cannot become a successful business result.

Status distinguishes absent application, unreachable endpoint, protocol error,
authorization required and explicit login failure. HTTP 401/403 is not treated
as proof of Taobao logout. Discovery returns protocol_ready, ready=false and
login=not_checked; only a completed semantic search returns ready=true.

The preexisting conditional direct-tool and cart admission implementation is
retained for isolated synthetic fixtures, but the real 3.0.0 production profile
publishes only connection status and qualified search. It never falls back to
those direct-tool bindings. Cart tombstones and stable intent IDs do not grant
cart access. No actual cart write is part of this work.

## Verification and installation boundary

Previously reviewed evidence covers the r2 boundaries, 52 SSE/transport and
compatibility checks, the real 20-tool/22-public-page exchange, and 23 nested
data-envelope failure checks. `Taobao300SearchTests.swift` adds focused search
fixture coverage and a separate live mode invoking `TaobaoRuntime.shared` with
its production application gate intact. Synthetic results and live results
are recorded separately. Older failed runs remain in the review evidence.

The current candidate preserves the 665-file source baseline
`9e6b074a8d942cabb05537f398f179296e50237b`, including the installed ARL 0.1.2
build6 NetEase diagnostic source. Its 18-input directed Swift compile and all
65 search checks passed. At 2026-10-08 18:02 UTC, the same compiled production
runtime, with its application gate intact, searched for `保温杯` through the
running official 3.0.0 app using `sourceApp=ARL`. It returned one public card
with a title and visible price `364`; product ID, URL and SKU stayed unknown.
This proves the candidate runtime's live search path, not installed ARL/Mio IPC
acceptance. No new full application build is claimed for this source packet.

This source candidate does not imply an installed ARL/Mio capability. Independent
business review, final combined manifest, fresh source guard, paired ARL/Mio
build/resource signing and installation, and installed IPC acceptance are
separate gates. Installed ARL build6 and service processes remain intact.
No login, AI toggle, extra permission, mcporter installation or real purchase is
performed by the integration.

## Current capability evidence and App consumer, 2026-10-09

The fresh official guide, 3.0.0 release page and guide-linked public reference
were read again. The installed 3.0.0 executable, Info.plist and app.asar pins
are unchanged, strict signature verification passed in the permitted read-only
execution context, and the fresh 20-tool directory has the same catalog digest.
A sandbox-only initial signature/network failure is recorded separately and
does not establish application tampering. No business tools were called in this
fresh protocol/catalog check.

`docs/TAOBAO-OFFICIAL-CAPABILITIES.json` records exact primary-source URLs,
timestamps, digests and the real tool names. The public reference still mentions
`search_products`; it is absent from the actual directory. The live directory
controls admission. Public guide comments are not official API contracts.

The isolated App candidate adds search input and displays only the completed
existing `TaobaoRuntime` projection: up to three titles and visible prices.
Missing/ambiguous prices remain unknown, failed operations clear old results,
and invalid ranks, invented links or inconsistent unknown fields are rejected
by the App result model. The success response explicitly retains
`login=not_checked`. Mio's existing named catalog/structured result consumer is
preserved; source-backed capability reasons travel through that same channel.

There is no direct official `get_product`, `get_product_detail`,
`get_product_skus`, `get_cart`, `request_sku_selection` or account-status tool
in the current external MCP directory. A fixed-selector
known-URL detail experiment is excluded from this product increment: it is
combination page reading, has no current live acceptance and must not be
presented as an official product API. Search links cannot be invented from
titles or ranks. `add_to_cart` is present upstream as legacy DOM compatibility,
but its description requires the absent official SKU panel for the new flow;
its presence does not qualify ARL cart access. General clicks cannot substitute
for that panel. Cart read lacks a qualified bounded privacy contract.

The new App consumer passed its frozen directed native validation on the
root-granted SECOND slot: 78 search checks, 144 diagnostic checks, both directed
compiles and the actual SwiftUI panel typecheck. The slot was released with
all child processes reaped and no pending processes. These offline checks do
not prove an installed App or a shopping workflow. The source candidate awaits
paired formal build/signing and the unique writer's adoption. It is not claimed
installed or live accepted. Deployment must add `Taobao300Capabilities.swift`
to both ARL and Mio source closures and `TaobaoProductResult.swift` to ARL,
preserve existing authority/permissions, refresh the signed combined manifest
and public executable pin, and perform installed status/search acceptance.
No real cart modification, order or payment test is part of acceptance.

### Supplier boundary: external MCP versus internal TaoClaw

Fresh pagination checks used the ARL identity and only initialization and
`tools/list`: two calls each returned the same 20 descriptors, with no
`nextCursor`. No business call, credential or setting read was required.

Restricted static decoding of `out/main/index.js` was compared byte for byte
with the current installed public ASAR entry. No application JavaScript was
executed. The resulting evidence distinguishes three facts:

- The bundle defines legacy `search_products` and `get_product_detail`, while
  the external built-in registry `Cu()` omits both and selects only
  `add_to_cart` from its product tool array. Their definitions do not grant ARL
  a direct API.
- `request_sku_selection` is an official internal TaoClaw panel explicitly
  included by the larger internal registry `Mu()`. It is absent externally;
  `get_product_skus` is separately filtered from the legacy array. This does
  not mean the official application lacks SKU capability.
- External dispatch checks the `Cu()` allowlist for source `mcp`. Built-in
  registration has no page/login predicate. Code mode wraps `Cu()` plus
  separately registered external tools; it does not add the internal SKU
  registry by default. No source impersonation, private dispatch, mode toggle
  or extra permission was attempted. Business login/authorization remains
  unverified.

The machine-readable capability evidence records exact source offsets and
excerpt hashes. The remaining supplier step is an official externally
advertised SKU/detail or bounded product/cart contract for ARL, with the
corresponding documentation and actual schema. If an official mode supplies
it, its real directory and semantics must be checked before enabling support.
An unadvertised internal method or unqualified selector is not a substitute.
