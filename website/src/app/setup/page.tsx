import Link from "next/link";
import { assistants } from "@/lib/assistants";

export const metadata = {
  title: "Setup | Cauchy",
  description:
    "Install Cauchy on macOS, connect an assistant or API key, export highlights, and move reading sessions between Macs.",
};

const REPO_URL = "https://github.com/thread3d/cauchy";
const DOWNLOAD_URL =
  "https://github.com/thread3d/cauchy/releases/latest/download/Cauchy.dmg";

const inline =
  "text-primary underline underline-offset-4 decoration-secondary/40 hover:decoration-primary transition-colors";
const code = "bg-card border border-border px-1.5 py-0.5 rounded text-[14px] text-primary";

function Block({ children }: { children: React.ReactNode }) {
  return (
    <div className="bg-card border border-border rounded-md p-4 my-6">
      <code className="text-[14px] text-primary">{children}</code>
    </div>
  );
}

export default function SetupPage() {
  return (
    <div className="w-full max-w-3xl mx-auto px-6 py-24 sm:py-32">
      <h1 className="text-[40px] sm:text-[56px] font-medium tracking-[-0.03em] leading-[1.1] text-primary mb-8">
        Setup
      </h1>

      <p className="text-[18px] leading-relaxed text-secondary">
        Install the native macOS reader, connect one of {assistants.length} assistant
        options, and keep your reading work with you.
      </p>

      <div className="max-w-none text-[16px] leading-relaxed text-secondary">
        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">Requirements</h2>
        <ul className="list-disc pl-6 space-y-2">
          <li>macOS 26.0 (Tahoe) or later.</li>
          <li>
            Ollama for local answers and reference indexing: start the server and pull a
            chat model. A Claude Code, Codex or Antigravity CLI, or an API key, can be
            used instead.
          </li>
          <li>
            Nothing else. There is no account to create and no license key.
          </li>
        </ul>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">Install</h2>
        <p>
          Download{" "}
          <a href={DOWNLOAD_URL} className={inline}>
            Cauchy.dmg
          </a>{" "}
          from the{" "}
          <a href={`${REPO_URL}/releases/latest`} target="_blank" rel="noopener noreferrer" className={inline}>
            latest release
          </a>
          , open it, and drag <strong className="text-primary">Cauchy.app</strong>{" "}
          into Applications. There is no Homebrew cask yet, and Cauchy is not on the Mac App
          Store &mdash; see{" "}
          <Link href="/faq" className={inline}>
            the FAQ
          </Link>{" "}
          for why.
        </p>
        <p className="mt-4">
          Ad-hoc signed builds can show &ldquo;Apple could not verify Cauchy is free of
          malware&rdquo; on first launch. If that happens, open it once
          from <strong className="text-primary">System Settings &gt; Privacy &amp; Security &gt; Open Anyway</strong>,
          and macOS stops asking.
        </p>
        <p className="mt-4">
          If instead you see <em>&ldquo;Cauchy is damaged and can&apos;t be opened&rdquo;</em>, you are on
          one of the v1.0.0&ndash;v1.0.2 builds, which shipped half-signed. Download{" "}
          <a href={`${REPO_URL}/releases`} target="_blank" rel="noopener noreferrer" className={inline}>
            v1.0.3 or later
          </a>
          , or clear the quarantine flag by hand:
        </p>
        <Block>xattr -dr com.apple.quarantine /Applications/Cauchy.app</Block>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">Build from source</h2>
        <p>
          Building needs Xcode 26 or later with the macOS 26 SDK &mdash; Command Line
          Tools alone cannot build the app. The full instructions, including the SwiftMath
          checkout and the project generator, are in the{" "}
          <a href={`${REPO_URL}#open-in-xcode`} target="_blank" rel="noopener noreferrer" className={inline}>
            README
          </a>
          .
        </p>
        <Block>git clone https://github.com/thread3d/cauchy.git &amp;&amp; cd cauchy &amp;&amp; ./scripts/run.sh</Block>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">
          Choose an assistant
        </h2>
        <p>
          Choose an assistant beside the ask field or in Settings → Assistant → Ask
          uses. Automatic picks a ready Claude Code, Codex or Antigravity CLI first,
          then Ollama, then an available API key. Choose Ollama explicitly when you want
          answers to stay local.
        </p>
        <p className="mt-4">
          For CLI connectors, open Settings → Connect your assistant and choose
          Install &amp; connect, or Connect if already installed. The guided flow
          installs the official CLI, opens provider sign-in in an embedded terminal,
          and checks the connection. Choose Use to select the connected assistant.
          Some connection checks send a tiny test message using your plan, without
          sharing a document.
        </p>
        <p className="mt-4">
          API connectors use Settings → Your API keys. Usage is billed by the
          provider separately from your consumer subscription. Keys are stored in
          the macOS Keychain and sent only to their corresponding vendor.
        </p>

        {assistants.map((assistant) => (
          <section key={assistant.id}>
            <h3 className="text-xl mt-8 mb-4 text-primary font-medium">{assistant.name}</h3>
            <p>{assistant.description}</p>
            <p className="mt-2">
              <a href={assistant.url} target="_blank" rel="noopener noreferrer" className={inline}>
                {assistant.id === "ollama" ? "Ollama setup" :
                  ["anthropicAPI", "openaiAPI", "gemini"].includes(assistant.id) ? "Get an API key" : "Official CLI documentation"}
              </a>
            </p>
          </section>
        ))}

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">Reference indexing</h2>
        <p>
          Indexing prefers the local Ollama model independently of the assistant selected
          for Ask. If the local model is unavailable, it can use a saved Gemini,
          Anthropic or OpenAI API key. In the Reference panel or Reading → Rebuild
          Reference Index, choose any available assistant model to rebuild. The panel
          records which model built the index. Cloud API indexing can send page text
          and rendered page images; CLI indexing sends text. See the{" "}
          <Link href="/legal/privacy" className={inline}>privacy policy</Link>.
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">Keep your reading work</h2>
        <ul className="list-disc pl-6 space-y-2">
          <li>File → Export Highlights as Markdown includes conversations, answer evidence boundaries and supplied pages.</li>
          <li>File → Save a Copy with Highlights creates PDF annotations readable in Preview.</li>
          <li>File → Export Reading Session saves the PDF, page and zoom, highlights, conversations, and completed evidence index and citation graph in a .cauchyreading package.</li>
          <li>Move that package to another Mac and use File → Open Reading Session or open it in Finder. Evidence stays bound to the packaged PDF with its model provenance; OCR navigation candidates are excluded.</li>
        </ul>
        <p className="mt-4">
          The dashboard searches highlights and conversations across your library.
          Hide from Recents keeps your work, and Show hidden restores papers. Use
          ⌘N for another reading window, ⇧⌘I to hide the context panel, and
          Settings → Reading to control reopening the last document at launch.
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">
          Why the app is unsandboxed
        </h2>
        <p>
          Claude Code, Codex and Antigravity work by spawning a locally installed CLI.
          The macOS{" "}
          <a href={`${REPO_URL}#sandbox`} target="_blank" rel="noopener noreferrer" className={inline}>
            App Sandbox
          </a>{" "}
          forbids that outright, so Cauchy ships unsandboxed and has the same access to
          your files as you do. That is also why it cannot be distributed through the Mac
          App Store.
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">Where files land</h2>
        <ul className="list-disc pl-6 space-y-2">
          <li>
            <code className={code}>~/Library/Application Support/Cauchy/workspaces/&lt;id&gt;/</code>{" "}
            &mdash; highlights, threads, viewport state, thumbnails.
          </li>
          <li>
            <code className={code}>~/Library/Application Support/Cauchy/reference-index/</code>{" "}
            &mdash; cached reference indexes and citation graphs, rebuilt on demand.
          </li>
          <li>
            Sidecar files written beside the PDF by older versions are migrated on open.
          </li>
        </ul>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">Still stuck?</h2>
        <p>
          Open an issue at{" "}
          <a href={`${REPO_URL}/issues`} target="_blank" rel="noopener noreferrer" className={inline}>
            github.com/thread3d/cauchy/issues
          </a>
          , or read the rest of the{" "}
          <Link href="/faq" className={inline}>
            FAQ
          </Link>
          .
        </p>
      </div>
    </div>
  );
}
