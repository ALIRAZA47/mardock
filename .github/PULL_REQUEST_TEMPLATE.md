<!-- Thanks for the pull request. CONTRIBUTING.md explains the checklist;
     delete anything that doesn't apply. -->

## Summary

<!-- What changes and why. If it closes an issue: "Closes #123". -->

## Test plan

<!-- How you checked it. -->

- [ ] `make test`
- [ ] `make audit` on the built app
- [ ] `make selftest` (for changes to the helper, the sandbox or the macOS Dock)
- [ ] Tried it on macOS <!-- version; Apple silicon or Intel -->

## Checklist

- [ ] No new dependencies, entitlements or permissions
- [ ] Helper changes come with validation, a rate limit, a SECURITY.md row and self-test coverage
- [ ] Engine or theme-number changes are mirrored in `playground/index.html`
- [ ] Anything a user would notice has a line under *Unreleased* in CHANGELOG.md
