# Created descriptor diagnostics, schema 3

This observes the descriptor already selected by the existing `user_playlists`
owner read. It does not repair or admit a descriptor. All existing checks,
endpoint/auth/signing/business rules, pagination, result mapping, write rules,
credential storage and native code remain byte-identical. Removing the marked
observation block and its single hook reproduces the canonical bridge exactly.

No descriptor string, name, path, parameter value, default value, provider reply,
token, credential or exception is emitted. Output uses the existing finite
`bridge / ignored` numeric diagnostics, original secret filter and sequence cap.
The observer runs once per existing owner read. It restores diagnostic phase,
last and lastValues; it cannot turn a rejection into acceptance.

## Fixed sequence and completeness

The sequence is exactly 21 code/sub_code pairs, `-97100` through `-97120` in that
order. Header sub_code is 3. R1/R2 were never adopted or installed; their earlier layouts
are superseded. R3 preserves all code positions and adds map inspection. A consumer must require the entire ordered
sequence, all finite fields, version, bounds and aggregate consistency before
reporting `series_complete`. It must separately require completion 0 before
reporting `descriptor_scan_complete`. Neither means an actual account read passed.

| Code | sub_code meaning |
| --- | --- |
| -97100 | Schema version, exactly 3 |
| -97101 | Method failure bitmask below, 0..16383 |
| -97102 | HTTP class: 0 undefined, 1 GET, 2 POST, 3 other string, 4 null, 5 other |
| -97103 | Provider class: 0 undefined, 1 null, 2 false, 3 numeric zero, 4 empty string, 5 netease, 6 other truthy, 7 other falsy |
| -97104 | Parameter container: 0 undefined, 1 null, 2 array, 3 object, 4 other |
| -97105 | Array/map entry count 0..4096; 4097 means greater than 4096; other containers are 0 |
| -97106 | Scanned entries; zero for unscanned/unsupported container |
| -97107 | OR of all scanned field failure masks below, 0..4095 |
| -97108 / -97109 | All occurrences of the fixed known names limit / offset |
| -97110 | Entries with neither fixed name, including nonobjects |
| -97111 | Duplicate known-name occurrences after each first occurrence |
| -97112 | Missing-name mask: bit 0 limit, bit 1 offset; 4 means unscanned/unknown |
| -97113 / -97114 | Number of object entries failing metadata / transform inactivity |
| -97115 / -97116 | Number of object entries failing default / required checks |
| -97117 | Number of entries with at least one field failure |
| -97118 / -97119 | Number of object entries failing any location predicate / type predicate |
| -97120 | 0 all array/map entries scanned; 1 oversized array/map, not scanned; 2 other container, not scanned; 3 diagnostic budget insufficient; 4 observer exception |

Every array or object-map entry is scanned when count <=4096, including entries
beyond the admitted maximum of two. There is no first-N sample. More than 4096
entries are not scanned; counts and masks from an unscanned container are not
assertions of absence. The 4097 count sentinel is explicitly inexact. Undefined,
null, boolean, numeric and string containers have no supported descriptor-entry
interpretation and are explicitly incomplete.

For map entries the observer uses exactly the pinned CLI's `{name:key,...value}`
precedence in an observation-only copy. An own name overrides the map key even
when it is null, false or an unknown name. Only fixed known-name counts and
predicate classifications are emitted; raw keys/values never leave the observer.
Map values of every JSON type use JavaScript spread semantics just as the CLI
(null/scalars contribute no named descriptor fields; strings/arrays contribute
numeric keys, which cannot become any observed named field). Their effective
field lacks location/type and the fixed failure bits show those gaps. All
metadata/transform/default/required predicates are inspected across map entries,
even when the original array-only check will reject the container first. Empty
maps are fully inspected and report both required names missing. No map-derived
copy is passed to production projection, no map is admitted, and method bits
3/4 still reject every map regardless of descriptor scan completeness.

At least 22 remaining diagnostic slots are needed: 21 for this series plus one
for an original immediate guard failure. Otherwise the observer emits only
`-97120 / 3`, if the existing 128-event cap permits it. At the full cap there is
no new event and the consumer reports incomplete. If a safe-number filter redacts
a code/value, or the sink fails, the consumer cannot claim completeness. No cap,
secret filter or sink behavior is relaxed. Exception marker 4 is best-effort and
may follow a partial series; that series is incomplete.

## Exact predicate coverage

Bit N below is `2**N`; a set bit means that existing predicate failed. All are
evaluated independently, even when an earlier original check will reject first.
Truthiness uses the original JavaScript semantics; no enum coercion is used to
decide whether auth_provider, in or location passes.

| Method bit | Existing predicate required to pass |
| --- | --- |
| 0 / 1 | metadata / preprocess inactive |
| 2 | fixed_params absent or exact empty object |
| 3 / 4 | parameters array / array length <=2 |
| 5 | method name is a permitted identifier and not $default |
| 6 | http_method exactly GET |
| 7 | auth_required exactly true |
| 8 | auth_provider falsy or exactly netease |
| 9 / 10 | path is string / string length <=256 |
| 11 | path matches the existing /openapi/(music\|v1)/ character grammar |
| 12 | path has no double slash |
| 13 | path equals the fixed created/get/v2 endpoint |

| Field bit | Existing predicate required to pass |
| --- | --- |
| 0 | field is nonnull, nonarray object |
| 1 / 2 | metadata / transform inactive |
| 3 | default absent, null or string/number/boolean |
| 4 | required undefined or boolean |
| 5 | name is limit or offset |
| 6 | fixed known name not already seen |
| 7 | in or location is query |
| 8 | in falsy or query |
| 9 | location falsy or query |
| 10 | in or location falsy, or they are equal |
| 11 | type is string, number, integer or boolean |

Inactive retains the exact existing definition: undefined, null, empty object
or empty array. For a nonobject field only bit 0 and the unknown/rejected entry
counts apply; member predicates are inapplicable. Known-name duplicate and
missing counts cover the entire scanned array/map. The diagnostic tracks names in
the received array/map independently of original short-circuit rejection so later
failures are visible; no unknown raw name enters a set or output.

Structural selection remains before the observation hook. Original codes
`-97004..-97008` still distinguish manifest/root/group/method selection rejection;
when there is no unique selected method, there is no descriptor series. This is
reported as incomplete, never as a clean descriptor. After projection, allowed
method/field key sets and absence of metadata/preprocess/default/transform are
construction invariants. Original checks remain in place; the pre-projection
activity/default checks are covered above. Search/effect-only branches of the
validator are inapplicable to this fixed user_playlists operation. Original
`-97001..-97050` continue to identify non-descriptor rejection stages, including
network/signing/business/result/storage guards. This diagnostic does not inspect
or claim to exhaust provider or user-account failures beyond the selected local
descriptor predicates.

## Readback and tests

The frozen review bundle includes `collect_read_contract.py` and
`test_readback.py`. The future live invocation takes a newly reviewed installation
receipt path, its exact SHA256 and one exact existing-owner call UUID. It verifies
the successful receipt, installed executable/bridge hashes and kernel process
generation before and after the bounded log query. Its predicate admits both
old -970 and new -971 families, with fixed subsystem/category/process/PID/prefix
and callID. It rejects unknown inner fields/codes, nonnumeric or out-of-range
values, incompatible phase/kind, extra private fields and inconsistent aggregates.
Only finite projections are saved; raw logs remain in bounded memory. It does
not invoke a provider, retrieve credentials or request login/permissions.

Example after exact new installation approval (not valid for installed ARL15):

```text
python3 collect_read_contract.py --live <new-install-RESULT.json> <receipt-sha256> <exact-call-id>
```

The modified official CLI regression requires the collector path as its fourth
argument (after node's script, candidate bridge and ServiceRuntime directory).
It uses the real pinned 0.1.7 CLI with synthetic credentials in memory and denied
real network. Eight scenarios assert exact 21 facts, wire sequence/cardinality,
original terminal rejection or successful synthetic read, then run these facts
through the same readback parser with the native field spelling. They cover
valid, simultaneous fixed-params/HTTP/metadata/transform/default/required failures,
unknown truthy provider/location, latent parameter rejection after method repair,
six-entry duplicates plus a sixth-entry metadata failure, admitted falsy
provider/location, a valid-looking map and an otherwise colliding map containing
hidden metadata/transform/default/required failures. This does not execute native unified logging or prove a real
provider read. Final installation still requires independent source and exact
signed-package/install review; no native source or compilation is proposed.
