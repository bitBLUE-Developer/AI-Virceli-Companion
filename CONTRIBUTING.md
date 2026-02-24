# Contributing to Virceli

Thanks for contributing.

## Scope
This repository targets the macOS app in:
- `native-macos`

## Development Setup
1. Open `Virceli.xcodeproj`.
2. Use the `Virceli` scheme.
3. Build and run in Xcode (`Cmd + R`).

## Contribution Rules
- Keep changes focused and reviewable.
- Prefer small PRs over large mixed PRs.
- Do not commit generated build artifacts (`dist`, `.app`, `.dmg`, caches).
- Keep UI text in English unless localization is introduced intentionally.
- Do not add secrets/tokens/credentials to source or resources.

## Pull Request Checklist
- Build succeeds locally in Xcode.
- Core flow tested:
  - Workspace select
  - Launch Claude Code
  - Resume session action
  - Unity launch/attach behavior
- README and docs updated if behavior changed.
- Asset/license notes updated if new assets are added.

## Issues
When reporting bugs, include:
- macOS version
- Virceli commit/tag
- Repro steps
- Console logs or screenshots if possible
