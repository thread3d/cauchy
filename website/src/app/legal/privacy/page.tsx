import Link from "next/link";

export const metadata = {
  title: "Privacy Policy | Cauchy",
  description:
    "Cauchy collects no telemetry. What stays on your Mac, and what a cloud connector sends when you ask a question.",
};

const REPO_URL = "https://github.com/jerrydjin/cauchy";

const inline =
  "text-primary underline underline-offset-4 decoration-secondary/40 hover:decoration-primary transition-colors";

export default function PrivacyPage() {
  return (
    <div className="w-full max-w-3xl mx-auto px-6 py-24 sm:py-32">
      <h1 className="text-[40px] sm:text-[56px] font-medium tracking-[-0.03em] leading-[1.1] text-primary mb-8">
        Privacy Policy
      </h1>

      <div className="max-w-none text-[16px] leading-relaxed text-secondary [&>p]:mb-4">
        <p className="text-secondary text-lg mb-8">
          Last updated: October 10, 2026
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">Local-First Architecture</h2>
        <p>
          Cauchy runs on your Mac and talks to no server of ours, because there is none.
          The app collects <strong className="text-primary">no telemetry</strong>,{" "}
          <strong className="text-primary">no analytics</strong> and{" "}
          <strong className="text-primary">no crash reports</strong>. We do not know when
          you open it, what you read, or what you ask.
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">Your Data</h2>
        <p>
          Workspaces &mdash; highlights, threads, viewport state and thumbnails &mdash; are
          written to{" "}
          <code>~/Library/Application Support/Cauchy/workspaces/</code>, and cached
          reference indexes to <code>~/Library/Application Support/Cauchy/reference-index/</code>.
          Anthropic, OpenAI and Gemini API keys live in the macOS Keychain. There is no
          automatic cloud sync. Deleting those folders removes local workspace and index
          data; saved API keys and any exports you created are stored separately.
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">
          What Leaves Your Mac When You Ask
        </h2>
        <p>
          Ask sends your question, selected text, surrounding context, conversation
          history, and reference excerpts and passages retrieved from the same PDF to
          the chosen assistant. Ask reference evidence uses PDF text excerpts, not OCR
          navigation candidates or model transcriptions. Which provider receives the
          request depends on your connector:
        </p>
        <ul className="list-disc pl-6 space-y-2 mt-4">
          <li>
            <strong className="text-primary">Ollama:</strong> runs on-device through
            the local server. Nothing leaves your Mac.
          </li>
          <li>
            <strong className="text-primary">Claude Code (Anthropic):</strong> Cauchy spawns
            the <code>claude</code> CLI you signed into; the request goes to Anthropic under
            your existing agreement and their{" "}
            <a href="https://www.anthropic.com/legal/privacy" target="_blank" rel="noopener noreferrer" className={inline}>
              privacy policy
            </a>
            .
          </li>
          <li>
            <strong className="text-primary">Codex (OpenAI):</strong> the same, through the{" "}
            <code>codex</code> CLI, under OpenAI&apos;s{" "}
            <a href="https://openai.com/policies/privacy-policy/" target="_blank" rel="noopener noreferrer" className={inline}>
              privacy policy
            </a>
            .
          </li>
          <li>
            <strong className="text-primary">Antigravity (Google):</strong> through the{" "}
            <code>agy</code> CLI and your Google sign-in, under Google&apos;s{" "}
            <a href="https://policies.google.com/privacy" target="_blank" rel="noopener noreferrer" className={inline}>
              privacy policy
            </a>
            .
          </li>
          <li>
            <strong className="text-primary">Anthropic API:</strong> sent directly to
            Anthropic with your API key, under Anthropic&apos;s{" "}
            <a href="https://www.anthropic.com/legal/privacy" target="_blank" rel="noopener noreferrer" className={inline}>
              privacy policy
            </a>.
          </li>
          <li>
            <strong className="text-primary">OpenAI API:</strong> sent directly to
            OpenAI with your API key, under OpenAI&apos;s{" "}
            <a href="https://openai.com/policies/privacy-policy/" target="_blank" rel="noopener noreferrer" className={inline}>
              privacy policy
            </a>.
          </li>
          <li>
            <strong className="text-primary">Gemini API (Google):</strong> sent directly to
            the Gemini API with your key, under the{" "}
            <a href="https://ai.google.dev/gemini-api/terms" target="_blank" rel="noopener noreferrer" className={inline}>
              Gemini API terms
            </a>
            .
          </li>
        </ul>
        <p className="mt-4">
          CLI connectors use your provider-managed local sign-in. The guided setup
          opens that provider&apos;s sign-in in an embedded terminal and does not persist
          a credential transcript. Some connection checks send a tiny test message
          using your plan without sharing a document. API keys you add are stored in
          the Keychain and read to authenticate requests to their corresponding vendor.
          Automatic selection prefers a ready CLI, then Ollama, then an available API
          key; select Ollama explicitly for local answers.
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">Reference Indexing</h2>
        <p>
          Building the reference index prefers the local Ollama model. If it is
          unavailable, a saved Gemini, Anthropic or OpenAI API key can supply the
          fallback. You can also choose an available assistant model when rebuilding.
          Cloud API indexing can send page text and rendered images of individual
          pages to that provider; CLI indexing sends page text through the selected CLI.
          Index results and the builder&apos;s model provenance are cached locally.
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">OCR and Exports</h2>
        <p>
          Vision text recognition runs on-device. OCR reference candidates retain the
          imperfect transcript and page region as unverified navigation aids; they are
          excluded from Ask reference evidence and portable evidence indexes.
        </p>
        <p>
          Markdown exports contain highlights, conversations and answer evidence.
          Annotated PDF copies contain the document and its highlights. A .cauchyreading
          export packages the PDF, page and zoom, highlights, conversations, and any
          completed evidence index and citation graph. These files go wherever you
          save or transfer them; anyone you share them with can read the included content.
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">This Website</h2>
        <p>
          The site is a static Next.js build hosted on Vercel and sets no analytics or
          advertising cookies. Downloads are served by GitHub Releases, which applies{" "}
          <a href="https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement" target="_blank" rel="noopener noreferrer" className={inline}>
            GitHub&apos;s privacy statement
          </a>
          .
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">Contact</h2>
        <p>
          Questions about this policy belong in{" "}
          <a href={`${REPO_URL}/issues`} target="_blank" rel="noopener noreferrer" className={inline}>
            a GitHub issue
          </a>
          . See also the{" "}
          <Link href="/legal/terms" className={inline}>
            terms of use
          </Link>
          .
        </p>
      </div>
    </div>
  );
}
