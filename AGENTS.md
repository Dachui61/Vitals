# AGENTS.md

Vitals — a personal macOS monitor: CPU load, CPU temperature, memory, power state.

## Agent skills

### Issue tracker

Issues, specs and the wayfinding map live as local markdown under
`.scratch/vitals/`: `map.md` plus one ticket per file under
`issues/NN-<slug>.md`, each with `Type:` / `Status:` / `Blocked by:` header
lines (plus `Claimed:` while a session works it). Research findings live
under `research/`, in commits prefixed `research:`, with a same-named
throwaway `research/<name>` branch as the working copy — the report is also
on `main` so ticket links resolve.

`./scripts/frontier.sh` lists the takeable tickets (open + unblocked +
unclaimed); `--all` shows every ticket's state; `--map` prints the map.

### Domain docs

Read `GLOSSARY.md` before naming things in code — the terms are opinionated,
and the "avoid" lists exist because the tempting synonym means something
else. Decision records live in `docs/adr/`.

## Build notes for this machine

- Xcode **Command Line Tools only** (no full Xcode): compile with `swiftc` /
  `swift build`, and hand-assemble the `.app` bundle.
- `swiftc` needs `-module-cache-path "$PWD/.modulecache" -Xcc
  -fmodules-cache-path="$PWD/.modulecache"` — the default module cache under
  `$TMPDIR` is not writable here. `@main` needs `-parse-as-library`.
- `sudo` is unavailable to agents in this environment, so anything requiring
  root must be handed to the user as an explicit command to run.
- The app bundle needs `LSUIElement=true` to stay out of the Dock.
