# Shared selected GET contract

ARL18 accepted the existing session and returned a complete, stable observed list (24 items, two pages, parent evidence). Subsequent search and playlist description calls failed at the same actual predicate: `-97009`, the selected method's top-level key allowlist, followed by cache-wrapper `-97014`. Closed diagnostics do not identify the extra key or prove the method, fixed_params type or parameter shape of either failed method. No private playlist/song content is part of this evidence.

This increment projects each selected GET read before the pinned CLI receives its manifest. Search selects only `search/song`; playlists select only `playlist/created`; playlist description selects both the existing fixed detail path and `playlist/tracks` path. The original validator still checks authentication, method, exact/qualified path, required parameters and query locations. Its resulting mapping still supplies argv, active path/method and exact signed-business checks to both network boundaries.

All four GET stages share the same normalization:

- Array/map parameters use the pinned CLI's `{name: mapKey, ...value}` precedence.
- Only owner-supplied parameters reach the CLI. Unused optional parameters are omitted, including their defaults. New required inputs are rejected. Null/absent `required` is optional; other non-boolean forms are rejected.
- Owner-supplied values cannot be replaced by provider defaults; defaults/display attributes are removed. `fixed_params` is removed because pinned CLI GET reads queryParams while fixed_params contributes solely to bodyParams.
- Method/parameter metadata permits only empty/null values or a finite list of inert display keys. Active/unknown behavioral metadata, preprocessing and transforms remain rejected. Parameter types, names, duplicates and locations remain checked.
- Unknown top-level display extensions and unselected methods/groups never reach Commander. Duplicate names among retained commands are rejected.

The created-only wrapper remains for existing focused fixture entry points. Its schema-3 observation is unchanged: old method/field masks describe the original descriptor shape and can precede a successful read after normalization. They are not current admission verdicts.

The final candidate passed 12 synthetic cases through the actual pinned official CLI and production projection, fetch and HTTPS boundaries: created/search/detail positives, plus method/auth/path/required/dependent-call/preprocess/location/duplicate-field/duplicate-command negatives. Synthetic responses contain extended metadata, defaults, map parameters and ignored optional fields; wire checks confirm that only owner values are sent. Network is mocked and real sockets denied. Credentials are generated in memory. Native logging and actual provider search/detail success are not claimed.

Write descriptors deliberately continue through their existing validator. Create/append still require their current exact fields, intent, target and once-effect handling; method metadata/extra keys and nonempty fixed_params can still be incompatible there. No real write was run, and this change does not establish write availability. No POST route or effect admission was added.

Source adoption, signing, installation and real search/detail acceptance require their subsequent exact reviews. The installed ARL18 is left running during this preparation.
