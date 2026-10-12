// App Attest verification boundary (production requirement, NOT
// implemented). Every request passes through `verify`, so enforcing
// attestation later means replacing this verifier, not re-plumbing the
// server. Until then the result is always "not_implemented", and the
// server refuses to start if ASTRA_REQUIRE_APP_ATTEST=true (config.ts).
import type { IncomingHttpHeaders } from "node:http";

export type AttestationResult =
  | { status: "verified" }
  | { status: "rejected" }
  | { status: "not_implemented" };

export interface ClientAttestationVerifier {
  verify(headers: IncomingHttpHeaders): Promise<AttestationResult>;
}

/// The only verifier today. It checks nothing and says so.
export const notImplementedVerifier: ClientAttestationVerifier = {
  verify: () => Promise.resolve({ status: "not_implemented" }),
};
