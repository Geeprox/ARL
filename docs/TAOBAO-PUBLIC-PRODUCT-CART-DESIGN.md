# Public product identity read and cart-read design

The official page tools have now read one real public Tmall product's identity
and stable title. The separate source candidate adds a named known-link reader
for ARL/Mio and an App input. This is a page workflow, not a newly discovered
upstream product API. Full details, SKU pricing and cart functionality remain
unqualified. The previous twelve-path candidate and its successful native
validation are preserved independently.

## Actual public-page evidence, 2026-10-10

The public search card title was read twice. Its normal product anchor was
identified from two matching indexed DOM results, accounting for a nested
highlight span. One `click_element(index:92)` call timed out; it was not
replayed. A later metadata-only reconciliation found the actual public product
URL and ID, then two bounded title-scope reads agreed. The original timeout
remains a failed request with unknown response outcome.

The actual observed URL was
`https://detail.tmall.com/item.htm?id=954227509625`, with title
`CHaKOLAB和序保温杯大容量吸管运动水杯便携杯子生日礼物咔哒杯`.
The supplier's scoped title text included an explicit matching `[商品id]` line.
An additional run navigated once to this already-known URL and read the same
identity/title twice, validating the intended known-link protocol route without
any DOM click. No price, SKU, login, order or shopping-write result was inferred.

The `scan_page_elements` response contained search controls and other cards
outside its requested card scope. Thus its `scope` argument was not demonstrated
to constrain the response in this build. This is a privacy blocker for using
that scanner on account pages. `read_page_content` yielded the requested public
title scope; each read's URL, offset, truncation and length were checked. These
are observations of this build/page, not general guarantees for cart layouts.

The initial filtered scan returned a not-found message echoing the title.
The probe initially labelled the echoed line a success despite having no index;
the immutable original and a correction receipt are retained. No click used
that result. Successful anchor identification came from subsequent actual DOM
structure; title substrings or an echoed error are not identity evidence.

## Concrete ARL / Mio consumption

`taobao_get_product` accepts exactly `{ "url": "https://detail.tmall.com/item.htm?id=<digits>" }`.
Only this canonical Tmall host/path and single numeric ID parameter are admitted;
arbitrary URLs, tracking/variant parameters, selectors, sourceApp, SKU and
account inputs are rejected. Taobao-host detail layouts have not been tested
and are not claimed supported by this candidate.

The owner retains the signed 3.0.0 application gate, exact 20-tool catalog pin,
truthful ARL source and endpoint rechecks. It navigates once to the known URL,
checks the actual reported host/path/unique ID, reads the fixed observed title
scope twice with current-page guards and strict length/offset/boolean limits,
checks the supplier item marker, rejects changed titles and returns only the
existing product projection. ID/URL/title are known; price, original price,
image, shop, SKU and remaining fields are null with explicit `unknown_fields`.
Success retains `login=not_checked`.

The owner registry emits status, search and this exact descriptor only. Existing
MioReadOwnerAdapter validates the descriptor and routes its named request through
authenticated owner IPC, exposing the structured result in the existing channel
(connector-facing name: `mio_taobao_get_product`). No general navigation or DOM
tool is published. The App adds a known-link input and strictly validates the
completed product projection; old results clear on start, refresh or failure.
Search cards still have no verified URL/ID, so the App does not invent clickable
search-result links.

## Cart read: proposed contract, not enabled

A future `taobao_get_cart` / `mio_taobao_get_cart` would serve an explicit user
request to view the current account's cart. The observed preset directory has
`cart`; that fact permits investigating a page route, not declaring a cart
read successful. Current source emits no cart descriptor and performs no cart
or order/history read.

Proposed input is an optional bounded keyword and integer limit 1–10. No URL,
selector, account, SKU, order or mutation input is accepted. Before publication,
qualify the exact cart preset/host/path and bounded visible-row selectors in
the installed official build. Use `navigate(page:cart)` and bounded
`read_page_content` only; verify the current page before/after each read. Never
use the unqualified DOM scanner, select/check a cart item, set quantity, choose
SKU, delete, add, checkout, pay or inspect order confirmation. No order/history
fallback supplies product identity. Redirects to login stop before text reads
and request user login in the official App; the tool does not handle credentials.

Return only each qualified visible row's title and unambiguous visible price,
plus verified ID/link/quantity if an official read contract actually supplies
them; unavailable values stay null. Existing selected specifications/SKU price
remain unknown until official rules explicitly support their read. Exclude
addresses, account handles, recipient details, order identifiers and raw page
text. Enforce per-row and total budgets, repeat row identity checks, and report
`complete=false` for budget/drift/unknown termination. Missing content is not
proof of an empty cart. Displayed cart prices and totals are not final checkout
quotes. A successful cart read does not establish a named account or purchase
readiness.

The first live cart read needs an explicit account-read request and a qualified
scope contract. This task performed design only. No new permission, background
monitor, cart write, order or payment test is included.

## Validation and adoption boundary

Actual official protocol reads passed for one public Tmall product. This does
not prove the new Swift implementation, App installation or Mio publication.
`TaobaoPublicProductTests.swift` adds targeted synthetic boundary checks against
the captured public fixture: URL/input admission, drift/login rejection before
page reads, marker mismatch, changed title, truncation/type/length errors,
honest unknown fields, strict App projection and named Mio consumption. Updated
search/diagnostic fixtures account for the third published descriptor. The exact new Swift bytes compiled and passed 37 product boundary checks,
77 search/Mio checks and actual panel typecheck at 2026-10-10 05:03 UTC. The
earlier 155-check native pass applies only to commit `00b4ec3` and its
twelve-path packet; that suite was not repeated. All five new stages passed
without source repair. SECOND is released; no install or real business call
was performed. Receipt hashes and compile commit are in the qualification JSON.

The extension is on an independent worktree/branch based on that commit. The
unique writer should verify its separate patch/preimages after adopting the
previous packet, review the new shared runtime/descriptor/closed diagnostic/App
contacts, then check the native receipt closure against the exact adopted source. Add
`Taobao300PublicProduct.swift` to ARL and Mio compiler closures and
`TaobaoPublicProductResult.swift` to the App; the completed focused product/search/Mio checks and panel typecheck cover
these bytes, while the old diagnostics remain attributed to their old bytes.
Revalidate any writer-combined source drift. Paired build/sign/install and
installed App/Mio known-link acceptance follow through the formal writer.
Do not use the previous native slot or transplant excluded old detail experiments.
