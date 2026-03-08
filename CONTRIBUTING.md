# Contributing to MacGamingFix

Thanks for contributing.

## Before You Start

- Keep changes focused and minimal.
- Prefer readable, explicit Swift code.
- Preserve accessibility and UX quality.
- Avoid unrelated refactors in bug-fix PRs.

## Development Workflow

1. Create a branch from `main`.
2. Make your changes.
3. Test with at least one real game scenario.
4. Open a pull request with:
   - Clear summary
   - Reproduction steps
   - Before/after behavior
   - Any tradeoffs or known limitations

## Reporting Bugs

Use the GitHub **Bug report** template.

Please include complete environment details, especially:

- Game title and version
- CrossOver/Wine version
- macOS version
- Dock position (left/right/bottom) and Dock settings
- Hot corner configuration
- Display layout (single/multiple, resolutions)
- Exact input/action that triggers the issue

Incomplete reports are hard to reproduce and may be closed until more data is provided.

## Code Style

- Swift only, no `any`-style shortcuts in typed logic.
- Favor early returns.
- Keep state-machine logic explicit and locally understandable.
- Add comments only where behavior is non-obvious.

## Security / Privacy

If you find a security-sensitive issue, do not open a public issue.
Contact the maintainer directly first.
