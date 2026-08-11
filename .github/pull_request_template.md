## What

<!-- One or two sentences: what changes, and why now. -->

## Scope

- [ ] iOS app / CribWireKit
- [ ] Backend
- [ ] Shared protocol or test vectors (`shared/`)
- [ ] CI / release tooling (`.github/`)
- [ ] Docs only

Related task in `docs/TASKS.md`: <!-- e.g. Phase 1 → "HMAC request authentication middleware" -->

## How it was verified

<!-- Commands run, devices used, what you actually observed. "CI is green" is
     not a verification of two-device behaviour. -->

## Checklist

- [ ] Tests cover the change (unit, and integration where services are involved)
- [ ] `shared/test-vectors/cribwire-v1.json` unchanged, or updated on **both** sides
      with the iOS and backend suites green
- [ ] No secrets, keys, tokens, certificates or `.p8` files added to the repo
- [ ] No plaintext media, payloads or push tokens added to logs
- [ ] Specs (`docs/specs/*.md`) updated if behaviour diverged from them
- [ ] `docs/TASKS.md` checkbox ticked only if the task is genuinely finished

## Security-sensitive?

Anything touching pairing, key derivation, sealed signaling, authentication or
the zero-knowledge invariant needs a `security-reviewer` pass against
`docs/specs/security.md` before merge.

- [ ] Not security-sensitive
- [ ] Security-sensitive — reviewed
