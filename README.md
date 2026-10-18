# cauchy

Native macOS PDF reader for dense technical textbooks, mathematics papers, and academic problem sets.

**[Download Cauchy for Mac](https://github.com/thread3d/cauchy/releases/latest/download/Cauchy.dmg)**

Needs macOS 26.0 or later. The first time you open it, go to System Settings, then Privacy & Security, and click Open Anyway.

MIT licensed — see [LICENSE](LICENSE).

## Requirements

- macOS 26.0 (Tahoe) or later
- **Xcode 26** (or later) with the macOS 26 SDK — Command Line Tools alone cannot build this app

Local answers and the default reference index run through
[Ollama](https://ollama.com). Install it, start the server, and pull at least
one chat model:

```bash
ollama serve
ollama pull qwen3.8:27b   # or any model you prefer
```

Cauchy discovers installed models at launch (and from Settings ▸ Refresh) and
talks to `127.0.0.1:11434` by default. Set `OLLAMA_HOST` if your server listens
elsewhere. A Claude Code, Codex, or Antigravity CLI, or a BYOK API key, remains
available as a cloud alternative.

Point `xcode-select` at your Xcode install if needed:

```bash
# If using the default App Store install:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# If using Xcode Beta:
sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer
```

## Features

- **PDF reading workspace** — continuous, single-page, and two-up layouts, thumbnails/contents sidebar, dashboard of recent documents, in-document find (⌘F), one document per window (⌘N) so a paper can sit beside the one it cites
- **Highlights with evidence-bound AI threads** — select text or drag regions, save highlights, and ask questions about them; answers render LaTeX via SwiftMath and retain a visible, portable boundary between PDF-only claims, outside knowledge, insufficient evidence, and an unverified model declaration. Each answer records the exact PDF pages supplied to its provider/model without pretending that page access proves every claim.
- **Highlight colours** — file highlights under five marker colours
- **Undo** — deleting a highlight (and its conversation) and recolouring are undoable with ⌘Z; a delete that would take a conversation with it asks first
- **Export** — highlights and their conversations as Markdown, including each answer's evidence boundary and supplied pages (File ▸ Export Highlights as Markdown), or a copy of the PDF with the highlights written in as real annotations (File ▸ Save a Copy with Highlights) so they survive in Preview
- **Continue on another Mac** — File ▸ Export Reading Session packages the PDF, current page and zoom, highlights, conversations, and any completed evidence index/citation graph into one `.cauchyreading` file; imported evidence is SHA-256-bound to the packaged PDF and retains its model provenance, while older sessions remain compatible
- **Library dashboard** — recent papers appear immediately; Hide from Recents preserves notes and conversations, with Show hidden to restore them
- **Focused reading** — collapse the context panel with ⇧⌘I; Fit to Width follows changes in the reading area
- **Library-wide search** — search every highlight and conversation across every document from the dashboard, and jump straight to the one you meant
- **Reference hover previews** — an evidence-first index of numbered statements, equations, and figure captions. Ollama builds it by default; the Reference panel lets you rebuild with any available assistant model. Previews lead with PDF text and the original page, label AI formatting separately, and keep later printed mentions collapsed. Local OCR labels on image-only pages remain visibly unverified and are not used as reference evidence (that evidence is the PDF text layer, not a model transcription). A dragged region with no text layer falls back to on-device Vision OCR, and that recognized text is what Ask sees for the highlight.
- **Ask-time retrieval** — a hybrid lexical/semantic index supplies relevant PDF text passages from other pages; saved answers retain clickable original-page regions for selected text, indexed references, and uniquely located, untruncated retrieved passages. These identify supplied inputs, not proof that the answer follows from them.
- **Multiple assistant providers** — local models through Ollama; Claude Code, Codex, or Antigravity (agy) CLIs using your own sign-in; or your own Anthropic, OpenAI, or Gemini API key
- **On-device OCR** — on-device Apple Vision text recognition, with a copy-as-LaTeX helper

The last document you were reading reopens at launch; turn that off in Settings ▸ Reading.

Headless tooling: `Cauchy --benchmark-indexing <pdf> [--ground-truth labels.json] [--pages N]` measures the production extractor against labelled truth and two deterministic baselines, including abstention, evidence ambiguity, and a failure atlas. See [`Benchmarks/README.md`](Benchmarks/README.md). `Cauchy --probe-retrieval <pdf> <query>` prints what retrieval would feed the assistant and whether each passage resolves to an exact PDF text region; `Cauchy --probe-mentions <pdf> <kind> <number> <defining-page>` prints later citation anchors without invoking a model; `Cauchy --probe-ocr <pdf> <page> fast --json [--output <dir>]` reports local OCR candidates and can render their page-region overlays.

Image-only pages—or scans whose text layer contains only a page number or short
watermark—receive conservative on-device OCR navigation candidates when
Cauchy can identify a numbered heading or right-margin equation label. These
candidates are orange, retain the imperfect OCR line and exact page region, and
are not used as reference evidence or included in portable evidence. If OCR finds no
reliable label, Cauchy reports the limitation instead of caching a successful
empty index.

## Open in Xcode

```bash
open Cauchy.xcodeproj
```

Build and run the **Cauchy** scheme (⌘R).

If source files show as missing in Xcode, regenerate the project:

```bash
python3 scripts/generate_xcodeproj.py
```

This also resolves the local SwiftMath package under `Packages/SwiftMath`. If that folder is missing, run once:

```bash
git clone --depth 1 --branch 1.7.3 https://github.com/mgriebling/SwiftMath.git Packages/SwiftMath
```

Or use the all-in-one script:

```bash
./scripts/run.sh
```

## Tests

```bash
xcodebuild test -project Cauchy.xcodeproj -scheme Cauchy -destination 'platform=macOS'
```

`CauchyTests` is generated alongside the app target, so rerun
`scripts/generate_xcodeproj.py` after adding a test file. The suite covers pure
logic — reference parsing, LaTeX normalization, export, model decoding, undo —
and runs on every push and pull request via `.github/workflows/ci.yml`.

After regenerating, **close and reopen** the Xcode project if you see “Missing package product 'SwiftMath'”.

## Project Structure

```
Cauchy/
├── App/              Entry point and environment
├── Models/           DocumentWorkspace, ReferencePin, ViewportState
├── ViewModels/       Workspace, viewport coordinator, reference engine
├── Views/            SwiftUI + Liquid Glass UI
├── PDFKitBridge/     AppKit PDFView representable and selection overlay
├── Services/         Persistence, OCR, PDF region rendering
└── Utilities/        Normalized coordinates, debouncing
```

## Persistence

Saves are debounced independently per document and flushed before quitting; a failed write keeps the app open for retry. Workspace state is saved under Application Support at `~/Library/Application Support/Cauchy/workspaces/<id>/` (highlights, notes, colours, viewport, thumbnails). A document belongs to exactly one window: opening one that is already open brings its window forward rather than starting a second reader that would save over the first. Reference-index caches live in `…/Cauchy/reference-index/`. Legacy sidecars beside the PDF are migrated automatically on open.

## Sandbox

The app ships **unsandboxed** — the Claude Code, Codex, and Antigravity assistant providers spawn the user's locally installed CLIs, which App Sandbox forbids. Bookmarks fall back to plain (non-security-scoped) bookmarks accordingly.

## Releases & Distribution

The project includes a GitHub Actions workflow (`.github/workflows/release.yml`) that builds a `.dmg` whenever a new tag (e.g., `v1.0.0`) is pushed to the repository.

The workflow signs the app either way, and picks the identity from what is configured:

| `MACOS_CERTIFICATE_P12` | Signature | What a user sees |
| --- | --- | --- |
| not set | ad-hoc | "Apple could not verify…" — installable via **System Settings > Privacy & Security > Open Anyway** |
| set | Developer ID, notarized and stapled | opens on double-click |

### Why the app must be signed even without a certificate

Building with `CODE_SIGNING_ALLOWED=NO` does not produce an unsigned app. It produces a **half-signed** one: `codesign` never runs over the bundle, so there is no `Contents/_CodeSignature`, but the linker still ad-hoc signs the arm64 executable on its own, because arm64 binaries cannot run unsigned at all. The executable therefore claims a resource seal that no `CodeResources` file backs:

```
Sealed Resources=none          # nothing sealed
CodeDirectory flags=0x20002(adhoc,linker-signed)
```

Gatekeeper treats that mismatch as corruption, not as a missing developer identity, and reports **"Cauchy is damaged and can't be opened. You should eject the disk image."** That message has no "Open Anyway" button — it blocks installation outright. Releases v1.0.0 through v1.0.2 shipped in this state.

The fix is the explicit `codesign` step in the workflow; ad-hoc is enough to make the bundle self-consistent, and downgrades the failure back to the ordinary approval prompt.

If a user hits the damaged error on one of those older releases, they can clear the quarantine flag by hand:

```bash
xattr -dr com.apple.quarantine /Applications/Cauchy.app
```

### Enabling notarization

Notarization needs a paid Apple Developer account. Once enrolled:

1. **Create a Developer ID certificate.** Generate a "Developer ID Application" certificate and export it as a `.p12`, then base64-encode it:

   ```bash
   base64 -i Certificates.p12 | pbcopy
   ```

2. **Create an app-specific password** for your Apple ID at [appleid.apple.com](https://appleid.apple.com).

3. **Add the secrets** under **Settings > Secrets and variables > Actions**:
   - `MACOS_CERTIFICATE_P12` — the base64 string from step 1.
   - `MACOS_CERTIFICATE_PASSWORD` — the `.p12` export password.
   - `APPLE_ID` — your Apple ID email.
   - `APPLE_APP_PASSWORD` — the app-specific password from step 2.
   - `APPLE_TEAM_ID` — your 10-character Developer Team ID.

No workflow edit is needed. The `Select signing identity` step switches paths on the presence of `MACOS_CERTIFICATE_P12`, and `Notarize DMG` activates with it.
