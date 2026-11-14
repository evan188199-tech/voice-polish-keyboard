# Proposed per-result correction review contract

This is a proposal for coordination, not a claim that the current bridge provides these fields. The Mac bridge/coordinator owner must review the schema and rollout before production use.

For a `BridgeResponse` with `outcome == text`, propose a `correctionReview` object atomically bound to the same non-null `jobID` and text before advancing the ordered delivery cursor:

```json
{"jobID":"<UUID>","text":"<result>","correctionReview":{"schemaVersion":1,"disposition":"required","rawTranscript":"<original ASR>","reviewText":"<text with the spoken instruction preserved for review>"}}
```

The three dispositions are `not_required`, `required`, and `unknown`. `not_required` must contain neither `rawTranscript` nor `reviewText` and permits the existing normal delivery path only with a matching job ID and nonempty text. `required` requires both nonempty strings, belongs to that exact job, enters review before insertion, and preserves the raw transcript for recovery. `unknown` enters quarantine. Use distinct review text and original text because script conversion and model processing can change characters; never infer either from a global status message. No contents should be logged.

Missing object, missing/mismatched job ID, unknown schema/version/disposition, empty result, absent/empty required transcript or review text, or conflicting not-required fields are all `unknown`: preserve safely, block automatic delivery, and explain the need for review or compatible host. An old host lacks this object; a new client must not silently interpret absence as `not_required`. An old client cannot enforce the new contract; deployment requires explicit version negotiation or an independently reviewed fail-closed migration plan.

Maintain FIFO while an item is reviewed or quarantined. Confirm once, reject stale job/session/cancelled responses, and revalidate target/session before any automatic insertion. An explicit user action can instead insert into the currently selected field, clearly labelled; it does not prove that the original field is still focused. No iOS proxy acknowledgement can prove the host accepted insertion. All persistence and crash/ack recovery require dedicated native tests.

`scripts/check_correction_wire_contract.sh` tests a proposed decoder with synthetic JSON only. `scripts/check_correction_delivery_contract.sh` intentionally remains red because the shipping BridgeResponse has no such per-result object. These fixtures are not the actual receiver or bridge.
