# Working in this repo

## "Commit and push"

Unless told otherwise, "commit and push" means landing the work on the main
line of both repos, not leaving it on a side branch:

- this repo: `main`
- the fork at `gtk/ghostty` (`puntium/ghostty`): `webmux-shell`, the branch
  `.gitmodules` tracks. The fork's own `main` is not its main line, so don't
  merge there.

Push the fork first, then commit the submodule pointer here, so the pointer
never names a commit that isn't on GitHub.
