# Created-playlist manifest projection

ARL14's two real owner reads at 2026-10-10 00:48:23-00:48:38 UTC failed with
`unreviewed_method_field` (-97009), followed by `manifest_contract_rejected`
(-97014). The earlier -97017 describes the CLI profile bootstrap rejected by the
existing route gate; it is nonterminal. The stored login session remains present.
The rejected extra field name and value were not collected. This change does not
claim they are a particular harmless field.

For `user_playlists` only, project the provider manifest into one minimal
`playlist created` descriptor before the pinned CLI stores or consumes it.
Only the existing GET route, named authentication, and query pagination contract
can pass the unchanged validator. Strip unselected commands, notices, unknown
fields, descriptions and owner-overridden scalar defaults. Reject nonempty
preprocessing/metadata, dependent calls, transforms, fixed business parameters,
duplicate selected groups/methods, and altered path/authentication/parameter
contracts. The owner supplies limit/offset; the unchanged signed-business gate
checks their exact values. All other operations retain their existing behavior.

This does not expand network routes, add writes, change credential storage,
request another QR login, or enable any new permission. A manifest can still be
rejected if its core contract or active metadata is incompatible.

Tests:
- NetEaseCreatedManifestProjectionTests.cjs: 40 checks, including 25 negative
  contract cases and two real Commander calls through the production boundary.
- NetEaseCreatedManifestOfficialCLITest.cjs: runs the hash-pinned official CLI
  and full candidate bridge, with synthetic encrypted credentials and an ESM
  transport fixture. Real socket connections are disabled. The production HTTPS
  admission and signed request validation still execute. It asserts one complete
  authorized read after two stable sweeps. Raw credential frames stay in memory.

Invocation uses the qualified embedded Node runtime. The projection test takes
candidate bridge, unchanged baseline bridge, and qualified Commander path. The
CLI test takes candidate bridge and the qualified ServiceRuntime directory.
Synthetic regression is not proof of successful access to the real account;
independent review and an installed-owner status/list read remain required.
