---
schemaVersion: 1
id: decision_ddns-service-hardening_20260926235203575_13d82299
createdAt: 2026-09-26T23:52:03.576Z
topic: "ddns-service-hardening"
language: en
basedOnHead: 2a98d69992959a0cd70c068b22c100065fffdefa
basedOnDiffFingerprint: sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
payloadDigest: sha256:9c76bdbd4a88f41832b6c086e701a65f5f0d0aa52afe6c3ce98699344cfaa454
actorId: claude
status: proposed
---

# DDNS service hardening: design decisions for slices H01-H07

Context: full read of lib/ at origin/main@2a98d69 (0.5.1), 2026-09-26. Slice set: guides/slices/ddns-service-hardening/. Measured defects: monitor never reads the desired-state file (desired-state slice 02 never implemented); 40 concurrent DesiredStateStore.declare/1 calls -> 2 ok / 38 errors / 1 record on disk; failed listing + AUTO_CREATE can duplicate A records; get_zone_ssl_mode bypasses decode_envelope; no pagination; implicit Req retries/timeouts; adoption endpoints accept tenant client tokens; `mix test --seed 8` fails 3 tests from env pollution.

Decisions:
1. File write serialization uses :global.trans/4 with [node()] via a stateless Defdo.DDNS.FileLock, not a GenServer - DesiredStateStore deliberately stays out of the supervision tree (boot-safety). Re-entrant for the same requester; verified in scratch. Rejected: supervised writer process; one global lock for both files.
2. New Defdo.DDNS.Intent is the single per-cycle source of DNS intent: desired-state file when configured, env+RecordStore when disabled. A broken file aborts the cycle; never fall back to env. Rejected: projecting the file into Application env.
3. Monitor processes CNAME-only domains (A ∪ AAAA mapping keys ∪ CNAME entry domains) so API-declared records converge.
4. Monitor lists each zone once per cycle via paginated fetch_dns_records/2; a listing error fails the domain and never auto-creates. Zone-id caching deferred.
5. Cycle status lives in an ETS table owned by the monitor (non-blocking reads). Rejected: GenServer.call (blocks behind the running cycle), :persistent_term (global GC on update).
6. Adoption HTTP endpoints are operator-only (auth mode :token); tenant clients get 403. Per-domain scoping rejected as a product decision.
7. Phase 2 (/ready, /v1/status, telemetry, heartbeat rewiring) is blocked on owner approval of product.md.