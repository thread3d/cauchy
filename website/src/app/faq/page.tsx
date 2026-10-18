import Link from "next/link";
import { assistants } from "@/lib/assistants";

export const metadata = {
  title: "FAQ | Cauchy",
  description:
    "What Cauchy is, which assistants it supports, where your data lives, and why it ships unsandboxed.",
};

const REPO_URL = "https://github.com/thread3d/cauchy";

const inline =
  "text-primary underline underline-offset-4 decoration-secondary/40 hover:decoration-primary transition-colors";
const code = "bg-card border border-border px-1.5 py-0.5 rounded text-[14px]";

function Q({ q, children }: { q: string; children: React.ReactNode }) {
  return (
    <div>
      <h2 className="text-2xl font-medium tracking-tight text-primary mb-4">{q}</h2>
      <div className="text-[16px] leading-relaxed text-secondary space-y-4">{children}</div>
    </div>
  );
}

export default function FAQPage() {
  return (
    <div className="w-full max-w-3xl mx-auto px-6 py-24 sm:py-32">
      <h1 className="text-[40px] sm:text-[56px] font-medium tracking-[-0.03em] leading-[1.1] text-primary mb-8">
        Frequently Asked Questions
      </h1>

      <p className="text-[18px] leading-relaxed text-secondary">
        Installation steps live in the{" "}
        <Link href="/setup" className={inline}>
          setup guide
        </Link>
        ; anything not answered here belongs in{" "}
        <a href={`${REPO_URL}/issues`} target="_blank" rel="noopener noreferrer" className={inline}>
          an issue
        </a>
        .
      </p>

      <div className="space-y-12 mt-12">
        <Q q="What is Cauchy?">
          <p>
            A native macOS PDF reader for studying mathematics. Open a paper,
            highlight a line or drag a box around a figure, and ask about it; the answer
            appears in a thread pinned to that spot, with mathematics typeset properly. It
            is built for dense technical textbooks, mathematics papers and problem sets.
          </p>
        </Q>

        <Q q="What can it actually do?">
          <ul className="list-disc pl-6 space-y-2">
            <li>Highlights in five colours with saved AI conversations, undo for recolouring and deletion, and confirmation before deleting a conversation.</li>
            <li>Evidence-bound answers with LaTeX, provider/model provenance, supplied pages and clickable original-PDF regions when the source can be located exactly.</li>
            <li>Reference previews for numbered statements, equations and figure captions, leading with PDF text and the original page, with AI formatting shown separately.</li>
            <li>Retrieval from other pages using keyword search and on-device sentence embeddings, plus library-wide search of highlights and conversations.</li>
            <li>Local OCR with LaTeX formatting; unverified OCR reference candidates on scans are for navigation and are excluded from Ask evidence and portable indexes.</li>
            <li>Markdown and annotated PDF export, plus portable .cauchyreading sessions to resume on another Mac.</li>
            <li>Continuous, single-page and two-up layouts, thumbnails, contents, contact sheet, ⌘F find, and one document per window with ⌘N.</li>
            <li>A recent-document dashboard with Hide from Recents and Show hidden; hiding preserves your reading work.</li>
          </ul>
        </Q>

        <Q q="Do the evidence labels guarantee that an answer is correct?">
          <p>
            No. An answer records the model&apos;s declared boundary: PDF-only claims,
            outside knowledge, insufficient evidence or an unverified basis. Cauchy
            records which PDF pages it supplied and checks cited source IDs against
            supplied locations. Missing or invalid links remain visible. These checks
            do not prove that every claim follows from the PDF; inspect the original
            page and verify the mathematics.
          </p>
        </Q>

        <Q q="How do reference previews and scanned pages work?">
          <p>
            Ollama builds the index by default. If unavailable, a saved
            Gemini, Anthropic or OpenAI key can supply the fallback. You can also
            rebuild with any available assistant model in the Reference panel or
            Reading → Rebuild Reference Index. The panel keeps the builder&apos;s
            provenance and leads with source evidence rather than AI formatting.
          </p>
          <p>
            On image-only pages, or pages with only a watermark or page number,
            conservative local OCR may find a numbered heading or equation label.
            Orange candidates show the imperfect line and its page region, are
            unverified, and never become Ask reference evidence or portable evidence.
            If no reliable label is found, Cauchy reports the limitation.
          </p>
        </Q>

        <Q q="Can I export highlights and conversations?">
          <p>
            File → Export Highlights as Markdown saves your highlights and threads,
            including each answer&apos;s evidence boundary and supplied pages. File →
            Save a Copy with Highlights writes real PDF annotations so the highlights
            also appear in Preview. Copy All Highlights as Markdown is available too.
          </p>
        </Q>

        <Q q="Can I continue reading on another Mac?">
          <p>
            File → Export Reading Session creates a .cauchyreading package containing
            the PDF, page and zoom, highlights, conversations, and any completed
            evidence index and citation graph. Transfer it yourself, then use File →
            Open Reading Session or open the package in Finder on the other Mac.
            Imported evidence is SHA-256-bound to the packaged PDF and retains its
            model provenance; older sessions remain compatible. This is a manual
            transfer, with no account or automatic sync.
          </p>
        </Q>

        <Q q="How do I find an old conversation or restore a hidden paper?">
          <p>
            Use the dashboard search to find highlights and conversations across
            documents, then jump to a result. Hide from Recents preserves your work;
            Show hidden lets you restore a paper. Cauchy reopens the last document at
            launch by default; turn that off in Settings → Reading. Use ⇧⌘I to
            collapse the context panel while reading.
          </p>
        </Q>

        <Q q="Which assistants can it use?">
          <p>
            {assistants.length} connectors: {assistants.map((assistant, index) => (
              <span key={assistant.id}>
                {index > 0 ? ", " : ""}
                <a href={assistant.url} target="_blank" rel="noopener noreferrer" className={inline}>
                  {assistant.name}
                </a>
              </span>
            ))}. The CLI connectors use your provider sign-in; the three APIs use
            your own keys. The{" "}
            <Link href="/setup" className={inline}>
              setup guide
            </Link>{" "}
            covers each one.
          </p>
        </Q>

        <Q q="What does it cost?">
          <p>
            The app is free. Ollama costs nothing to run beyond the model download. The CLI connectors
            bill against the Anthropic, OpenAI or Google plan you already have, and the
            Anthropic, OpenAI and Gemini APIs bill your own keys separately. Cauchy has no server, no account and no
            subscription of its own.
          </p>
        </Q>

        <Q q="Where is my data stored?">
          <p>
            Saved locally on your Mac. Workspaces &mdash; highlights, threads, viewport
            state and thumbnails &mdash; live in{" "}
            <code className={code}>~/Library/Application Support/Cauchy/workspaces/</code>,
            and cached reference indexes in{" "}
            <code className={code}>~/Library/Application Support/Cauchy/reference-index/</code>.
            API keys are kept in the macOS Keychain. Exported reading sessions go
            wherever you save them; there is no automatic cloud sync.
          </p>
        </Q>

        <Q q="Does Cauchy send my PDFs to the cloud?">
          <p>
            Ask sends your question, selected text, surrounding context, conversation
            history and retrieved PDF passages to the cloud connector you choose.
            Reference indexing is a separate operation: using a cloud API can send
            page text and rendered page images, while CLI indexing sends page text.
            Ollama runs on-device. Provider requests are subject to their
            own terms.
          </p>
          <p>
            Cauchy itself collects no telemetry and no analytics. See the{" "}
            <Link href="/legal/privacy" className={inline}>
              privacy policy
            </Link>
            .
          </p>
        </Q>

        <Q q="Does it work offline?">
          <p>
            Reading, highlighting, local OCR, search and exports work offline.
            Answers and reference indexing can run locally when Ollama is running with
            a model installed. Choose it explicitly for local answers: Automatic
            prefers a ready CLI before the local model. All CLI and API connectors need
            a network.
          </p>
        </Q>

        <Q q="Why is the app unsandboxed?">
          <p>
            The Claude Code, Codex and Antigravity connectors work by spawning CLIs
            installed in your shell, which the macOS{" "}
            <a href={`${REPO_URL}#sandbox`} target="_blank" rel="noopener noreferrer" className={inline}>
              App Sandbox
            </a>{" "}
            forbids. Running unsandboxed means the app has the same access to your files as
            your user account does, and that it cannot be shipped through the Mac App
            Store.
          </p>
        </Q>

        <Q q="macOS says the app is damaged, or cannot be verified. Now what?">
          <p>
            Ad-hoc signed releases can show &ldquo;Apple could not verify&hellip;&rdquo;.
            If that happens, open the app once from{" "}
            <strong className="text-primary">System Settings &gt; Privacy &amp; Security &gt; Open Anyway</strong>.
          </p>
          <p>
            &ldquo;Cauchy is damaged and can&apos;t be opened&rdquo; means you have a v1.0.0&ndash;v1.0.2
            build, which shipped half-signed and is blocked outright. Get{" "}
            <a href={`${REPO_URL}/releases`} target="_blank" rel="noopener noreferrer" className={inline}>
              a newer release
            </a>{" "}
            or run{" "}
            <code className={code}>xattr -dr com.apple.quarantine /Applications/Cauchy.app</code>.
          </p>
        </Q>

        <Q q="Which macOS versions are supported?">
          <p>
            macOS 26.0 (Tahoe) and later. Earlier versions are not supported: the app
            is built against the macOS 26 SDK and uses Liquid Glass APIs that do not
            exist before it.
          </p>
        </Q>

        <Q q="Is it open source? Can I build it myself?">
          <p>
            Yes, under the{" "}
            <a href={`${REPO_URL}/blob/main/LICENSE`} target="_blank" rel="noopener noreferrer" className={inline}>
              MIT license
            </a>
            , at{" "}
            <a href={REPO_URL} target="_blank" rel="noopener noreferrer" className={inline}>
              github.com/thread3d/cauchy
            </a>
            . Building needs Xcode 26 or later with the macOS 26 SDK; the{" "}
            <a href={`${REPO_URL}#open-in-xcode`} target="_blank" rel="noopener noreferrer" className={inline}>
              README
            </a>{" "}
            has the steps, including the local{" "}
            <a href="https://github.com/mgriebling/SwiftMath" target="_blank" rel="noopener noreferrer" className={inline}>
              SwiftMath
            </a>{" "}
            checkout that renders the mathematics.
          </p>
        </Q>

        <Q q="Is there a Homebrew cask, or an iPad version?">
          <p>
            Neither, for now. Installation is the{" "}
            <a href={`${REPO_URL}/releases/latest`} target="_blank" rel="noopener noreferrer" className={inline}>
              .dmg from the latest release
            </a>
            , and Cauchy is macOS-only.
          </p>
        </Q>
      </div>
    </div>
  );
}
