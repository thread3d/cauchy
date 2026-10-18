---
name: verify
description: Build, launch, and observe the Cauchy macOS app to verify changes at runtime.
---

# Verifying Cauchy changes

## Build & launch

Everything needs `DEVELOPER_DIR` (xcode-select points at CommandLineTools):

```bash
export DEVELOPER_DIR=/Users/jerryjin/Downloads/Xcode-beta.app/Contents/Developer
python3 scripts/generate_xcodeproj.py       # required after adding/removing Swift files; also needs DEVELOPER_DIR (runs xcodebuild internally)
xcodebuild -project Cauchy.xcodeproj -scheme Cauchy -configuration Debug build
```

Built app: `~/Library/Developer/Xcode/DerivedData/Cauchy-*/Build/Products/Debug/Cauchy.app`.

There is a `CauchyTests` unit-test target (generated alongside the app target,
so it needs the generator rerun after adding a test file):

```bash
xcodebuild test -project Cauchy.xcodeproj -scheme Cauchy -destination 'platform=macOS'
```

The tests cover pure logic only — parsing, export, model decoding. Anything
touching the reader itself is still verified by build + driving the app.

## Gotcha: stale debug instances eat open events

If Xcode has a paused debug session of Cauchy, that process is suspended and
**traced** (`ps` STAT `SX`) — it survives `kill -9` until the debugger detaches,
and LaunchServices routes all activate/open events to it, so `open -a` appears
to do nothing. Check and clear before testing:

```bash
pgrep -x Cauchy | xargs -n1 ps -o pid,ppid,stat,command -p   # STAT "SX" = traced
# kill the debugserver parent (PPID), which releases the app process
pkill -9 -x Cauchy
```

Never `pkill -f` with a pattern containing "Cauchy.app" — it matches the tool
shell's own command line and kills it.

## Observing without a GUI session

App state is persisted, so many flows are verifiable from the shell:

- Opening a document creates/updates `~/Library/Application Support/Cauchy/workspaces/<uuid>/summary.json` (`documentURL`, `lastOpenedAt`) within ~1 s (saves are debounced 0.5 s).
- Reference-index caches: `~/Library/Application Support/Cauchy/reference-index/<sha256>-v3.json`.
- Launch pruning keeps the 50 most-recently-touched cache files and deletes older-than-180-days beyond that; seed fakes with `touch -t` to test.
- File-open path: `open -a <app> file.pdf` (cold and while running) → assert exactly one workspace per document URL.
- Headless modes: `Cauchy --benchmark-indexing <pdf>`, `Cauchy --probe-retrieval <pdf> <query>`.

`Logger` output does not show up in `log show` on this macOS 26 SDK even at
error level — use marker files (`try? Data(...).write(to: /tmp/...)`) for
which-code-path-ran questions instead.

Interactive UI checks (menus, find bar, dialogs) need the computer-use tools
and a user access grant for "Cauchy"; if denied, list those checks as
not-exercised rather than guessing.

## Open-event handling (regression trap)

Finder/dock opens are handled by `.onOpenURL` in `Cauchy/App/CauchyApp.swift`.
On this OS, an `NSApplicationDelegateAdaptor` implementing
`application(_:open:)` ALSO receives the same event — having both means every
file opens twice (and can create duplicate workspace dirs). Keep exactly one
handler.
