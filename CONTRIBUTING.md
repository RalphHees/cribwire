# Contributing to CribWire

## What's welcome

- **Pull requests for new features, bug fixes, or improvements.** Open a PR
  against this repository and it'll be reviewed. See the PR template
  (`.github/pull_request_template.md`) for what to include, and
  `docs/TASKS.md` for the current roadmap if you're looking for something
  to work on.
- **Support requests and bug reports.** Open an issue describing what you
  expected and what happened.
- **Questions about the project.** Also welcome as issues.

## What's not permitted

This project is source-available, not open source. See [LICENSE](LICENSE)
for the full terms. In short:

- You may **not** copy or redistribute this codebase, in whole or in part,
  outside of this repository.
- You may **not** fork this repository (or otherwise copy the source) to
  build, package, or ship your own version of the app or a derivative of
  it — modified, renamed, or otherwise.
- Submitting a pull request does not grant you any right to redistribute
  or fork the Software beyond what the license allows.

If you want to use this codebase for something beyond contributing back
(e.g. a commercial license), contact info@ralphhees.nl.

## Security-sensitive changes

Anything touching pairing, key derivation, sealed signaling, authentication,
or the zero-knowledge invariant should be reviewed against
`docs/specs/security.md` before merge — flag this in your PR.
