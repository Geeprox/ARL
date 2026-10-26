# Tisra consumer alignment, 2026-10-01

Coordination only; no provider/product registration, execution grant, migration, upload, model call or deployment. Tisra owner reports the research/service/storage/adapter/Swift/test inputs match the supplied source API v1 manifest, but REAL-CAPABILITY-ACCEPTANCE.md has changed. Aggregate78faf… must not be described as a currently verified whole set. This turn did not independently rerun that aggregate audit or modify Tisra.

Agreed consumer requirements, before execution:

- Map the existing local Codable descriptor to the wire descriptor with explicit null parentRunID/parentFingerprint; preserve the old Ledger bytes/evidence. Original request bytes remain an independent512KiB budget, descriptor32KiB, reply1MiB, arl/1 full frames16KiB/64KiB.
- Strictly negotiate all three request/output/history formats, real provider evidence, exact model fingerprint and every advertised limit. implementation_only/test_double is not live provider acceptance. A local semantic format string is not compatibility evidence.
- Persist owner/job/run/requestHash/epoch/authEpoch and cancellation binding. Pin the authorization revision from the first accepted receipt; reject revision drift, noncanonical UUIDs/references, unknown keys and inconsistent state/result/cancel combinations before committing any Ledger result.
- If upload/submission is aborted, explicitly revoke every payload which was created, preserving uncertain submission/run tombstones. TTL and an in-memory receipt alone are not cancellation/recovery. Never automatically replay an uncertain external call.

ARL source SDK open items: research_client.py currently bounds auth_epoch as text rather than pinning it across receipts; its upload path does not yet provide abort cleanup/revocation of staged payloads. These need a separately tested source SDK hardening increment, coordinated with the Swift consumer; they are not marked fixed here. Production App must continue to refuse execution meanwhile. Existing server grant/CAS invalidation is not a substitute for consumer matching/persistence.

Codex text migration stays separate (TISRA-CODEX-MIGRATION.md): preserve old runs/raw Responses/encrypted history/citations. A new explicitly reviewed branch carries only selected public answers/citations; do not forward encrypted reasoning, forge a Responses envelope, silently truncate original bytes, or claim a4096 hard token limit. New request/output/history versions and honest byte/time/call bounds must be accepted and tested before use. The real text transport smoke is not research compatibility/quality acceptance.

No source API format has been changed by this coordination note. Frozen Notes/Friday artifacts and installed metadata-only host remain outside this scope; activation/credential/account/paid-model permissions remain separate.
