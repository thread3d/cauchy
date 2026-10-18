import Link from "next/link";
import Image from "next/image";
import { ArrowUpRight } from "lucide-react";
import MathBackground from "@/components/MathBackground";
import { assistants } from "@/lib/assistants";

const DOWNLOAD_URL =
  "https://github.com/jerrydjin/cauchy/releases/latest/download/Cauchy.dmg";
const REPO_URL = "https://github.com/jerrydjin/cauchy";

const inline =
  "text-primary underline underline-offset-4 decoration-secondary/40 hover:decoration-primary transition-colors";

export default function Home() {
  return (
    <>
      {/* Animated 3D Math Grid Background */}
      <div className="absolute top-0 left-0 w-full h-[150vh] pointer-events-none z-0">
        <MathBackground />
      </div>
      {/* Hero Section */}
      <section className="w-full pt-20 pb-16 px-6 flex flex-col items-center text-center relative z-10">

        <div className="relative z-10 w-full flex flex-col items-center">

          <h1 className="text-[64px] sm:text-[80px] lg:text-[100px] font-medium tracking-[-0.03em] leading-[1.05] text-primary max-w-[1000px] mb-4">
            A PDF reader that <br className="hidden sm:block"/>talks back.
          </h1>

          <p className="text-[22px] sm:text-[28px] text-secondary max-w-3xl mb-12 font-normal tracking-[-0.01em]">
            Built for dense mathematics papers. Highlight <br className="hidden sm:block"/>equations to ask your AI assistant questions.
          </p>

          <div className="flex flex-col sm:flex-row items-center gap-4 mb-4">
            <Link
              href={DOWNLOAD_URL}
              className="w-full sm:w-auto h-12 flex items-center justify-center bg-accent text-accent-text px-8 rounded-md text-[16px] font-medium whitespace-nowrap hover:bg-accent-hover transition-colors"
            >
              Download for macOS
            </Link>
            <a
              href={REPO_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="w-full sm:w-auto h-12 flex items-center justify-center gap-1.5 bg-card text-primary px-6 rounded-md text-[16px] font-medium hover:bg-black/5 transition-colors"
            >
              View the source <ArrowUpRight className="w-4 h-4" />
            </a>
          </div>

          <p className="text-[14px] text-secondary mb-20">
            Free and MIT licensed. Requires macOS 26 (Tahoe) or later; ad-hoc
            signed builds need Open Anyway ·{" "}
            <Link href="/setup" className={inline}>
              installation notes
            </Link>{" "}
            ·{" "}
            <a
              href="https://github.com/jerrydjin/cauchy/releases"
              target="_blank"
              rel="noopener noreferrer"
              className={inline}
            >
              all releases
            </a>
          </p>

          {/* Hero Image / App Mockup Area */}
          <figure className="w-full max-w-[1200px]">
            <div className="bg-card rounded-3xl overflow-hidden relative">
              <Image src="/app-screenshot.png" width={3300} height={2168} className="w-full h-auto" alt="Cauchy showing a highlighted Cayley–Hamilton theorem and a conversation with answer evidence and PDF source links" priority quality={100} />
            </div>
          </figure>
        </div>
      </section>

      {/* Features Grid */}
      <section className="w-full py-24 sm:py-32 px-6 bg-transparent relative z-10">
        <div className="max-w-[1400px] mx-auto">

          <div className="mb-16 flex flex-col md:flex-row md:items-end justify-between gap-8">
            <div>
              <h2 className="text-[40px] sm:text-[56px] font-medium tracking-[-0.03em] leading-[1.1] text-primary">
                A reading environment for deep work.
              </h2>
              <p className="text-[40px] sm:text-[56px] font-medium tracking-[-0.03em] leading-[1.1] text-secondary">
                Designed for papers, problem sets, and textbooks.
              </p>
            </div>
          </div>

          <div className="flex flex-wrap gap-4 mb-12">
            <Link href={DOWNLOAD_URL} className="bg-accent text-accent-text px-5 py-2.5 rounded-md text-[15px] font-medium hover:bg-accent-hover transition-colors">
              Download App
            </Link>
            <Link href="/setup" className="bg-card text-primary px-5 py-2.5 rounded-md text-[15px] font-medium hover:bg-black/5 transition-colors">
              Setup Guide
            </Link>
            <a
              href={`${REPO_URL}#features`}
              target="_blank"
              rel="noopener noreferrer"
              className="bg-card text-primary px-5 py-2.5 rounded-md text-[15px] font-medium hover:bg-black/5 transition-colors flex items-center gap-1.5"
            >
              Read the README <ArrowUpRight className="w-4 h-4" />
            </a>
          </div>

          {/* Grid Layout mimicking Ramp */}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">

            {/* Large Card 1 */}
            <div className="bg-card rounded-3xl p-8 sm:p-12 min-h-[500px] flex flex-col relative overflow-hidden group">
              <h3 className="text-[28px] font-medium tracking-[-0.02em] leading-[1.2] text-primary max-w-[80%] z-10 mb-4">
                <span className="text-primary">Highlight & Chat</span><br/> Ask questions directly in context
              </h3>
              <p className="text-[16px] text-secondary z-10 mb-8 max-w-[80%] leading-relaxed">
                Select a line of text or drag a box around a figure. Cauchy saves the
                highlight and opens a thread pinned to that spot. Answers keep their
                provider, model, supplied PDF pages and model-declared boundary: PDF basis,
                outside knowledge, insufficient evidence or unverified. Click source
                links to inspect the original PDF; page access does not prove a claim.
              </p>

              {/* Simple Chat UI Mockup */}
              <div className="mt-auto bg-background rounded-2xl p-6 w-[90%] mx-auto z-10 border border-border/50">
                <div className="w-full flex justify-end mb-4">
                  <div className="bg-accent/20 text-accent-text px-4 py-2 rounded-2xl rounded-tr-none text-sm inline-block max-w-[80%]">
                    Can you explain the proof for Lemma 4.1?
                  </div>
                </div>
                <div className="w-full flex justify-start">
                  <div className="bg-card border border-border/50 px-4 py-3 rounded-2xl rounded-tl-none text-sm inline-block max-w-[90%] text-secondary leading-relaxed">
                    <p className="text-xs font-medium text-primary mb-2">Illustrative answer · Insufficient evidence</p>
                    The supplied passage states Lemma 4.1, but does not include its proof.
                    I need the proof page to explain the author&apos;s argument.
                  </div>
                </div>
              </div>
            </div>

            {/* Large Card 2 */}
            <div className="bg-card rounded-3xl p-8 sm:p-12 min-h-[500px] flex flex-col relative overflow-hidden group">
              <h3 className="text-[28px] font-medium tracking-[-0.02em] leading-[1.2] text-primary max-w-[80%] z-10 mb-4">
                <span className="text-primary">Reference Previews</span><br/> Never lose your place again
              </h3>
              <p className="text-[16px] text-secondary z-10 mb-8 max-w-[80%] leading-relaxed">
                When an author cites &ldquo;Theorem 2.1&rdquo; forty pages later, hover it.
                Previews lead with the original PDF text and page for numbered statements,
                equations and figure captions, with AI formatting labelled separately.
                Later printed mentions stay collapsed. Indexing prefers the local Ollama model;
                rebuild with any available assistant model from the Reference panel.
              </p>

              {/* Abstract Reference Hover Mockup */}
              <div className="mt-auto bg-background rounded-2xl p-6 w-[85%] mx-auto z-10 border border-border/50">
                 <div className="text-secondary text-sm mb-3 leading-relaxed">
                   By applying <span className="bg-accent/30 text-accent-text px-1 rounded cursor-pointer border border-accent/50">Theorem 2.1</span> to our matrix...
                 </div>
                 {/* Hover Popover */}
                 <div className="bg-card border border-border shadow-sm rounded-xl p-4 w-4/5">
                   <div className="text-sm font-medium text-primary mb-2">Theorem 2.1 · p. 12</div>
                   <div className="text-xs text-secondary mb-2">Source evidence · Original PDF</div>
                   <div className="w-full h-1.5 bg-border rounded-full mb-1.5"></div>
                   <div className="w-3/4 h-1.5 bg-border rounded-full"></div>
                 </div>
              </div>
            </div>

            {/* Small Card 1 */}
            <div className="bg-card rounded-3xl p-8 sm:p-12 min-h-[300px] flex flex-col justify-center relative overflow-hidden group">
              <h3 className="text-[28px] font-medium tracking-[-0.02em] leading-[1.2] text-primary mb-3">
                Native LaTeX rendering
              </h3>
              <p className="text-[16px] text-secondary max-w-[90%] leading-relaxed">
                Answers are typeset by{" "}
                <a href="https://github.com/mgriebling/SwiftMath" target="_blank" rel="noopener noreferrer" className={inline}>
                  SwiftMath
                </a>
                , a native math renderer &mdash; no webview, no MathJax, no layout jump while
                a proof streams in.
              </p>
            </div>

            {/* Small Card 2 */}
            <div className="bg-card rounded-3xl p-8 sm:p-12 min-h-[300px] flex flex-col justify-center relative overflow-hidden group">
              <h3 className="text-[28px] font-medium tracking-[-0.02em] leading-[1.2] text-primary mb-3">
                On-device OCR for equations
              </h3>
              <p className="text-[16px] text-secondary max-w-[90%] leading-relaxed">
                Drag a box over an equation the PDF stores as unselectable artwork. Apple&apos;s{" "}
                <a href="https://developer.apple.com/documentation/vision" target="_blank" rel="noopener noreferrer" className={inline}>
                  Vision
                </a>{" "}
                framework recognizes text locally, with LaTeX formatting and copying.
                On scanned pages, orange OCR reference candidates retain the imperfect
                transcript and page region for inspection. These navigation candidates
                are unverified and are excluded from Ask evidence and portable indexes.
              </p>
            </div>

            {/* Small Card 3 */}
            <div className="bg-card rounded-3xl p-8 sm:p-12 min-h-[300px] flex flex-col justify-center relative overflow-hidden group">
              <h3 className="text-[28px] font-medium tracking-[-0.02em] leading-[1.2] text-primary mb-3">
                Retrieval across the whole document
              </h3>
              <p className="text-[16px] text-secondary max-w-[90%] leading-relaxed">
                An ask does not stop at the highlight. Cauchy pulls the exact statements a
                question cites and the passages that match it, combining{" "}
                <a href="https://en.wikipedia.org/wiki/Okapi_BM25" target="_blank" rel="noopener noreferrer" className={inline}>
                  BM25
                </a>{" "}
                keyword search with on-device sentence embeddings. Saved answers retain
                clickable PDF regions when a supplied passage can be located exactly.
                The links identify inputs to the answer; they do not verify its reasoning.
              </p>
            </div>

            {/* Small Card 4 */}
            <div className="bg-card rounded-3xl p-8 sm:p-12 min-h-[300px] flex flex-col justify-center relative overflow-hidden group">
              <h3 className="text-[28px] font-medium tracking-[-0.02em] leading-[1.2] text-primary mb-3">
                A workspace, not a viewer
              </h3>
              <p className="text-[16px] text-secondary max-w-[90%] leading-relaxed">
                Continuous, single-page and two-up layouts, a sidebar that switches between
                thumbnails, table of contents and contact sheet, in-document find (⌘F), and a
                dashboard of recent documents. Scroll position, highlights and threads are
                restored per document. Open another window with ⌘N, hide the context
                panel with ⇧⌘I, and use Fit to Width as your reading area changes.
              </p>
            </div>

            <div className="bg-card rounded-3xl p-8 sm:p-12 min-h-[300px] flex flex-col justify-center">
              <h3 className="text-[28px] font-medium tracking-[-0.02em] text-primary mb-3">
                Highlights you can keep
              </h3>
              <p className="text-[16px] text-secondary leading-relaxed">
                Organise highlights in five marker colours. Recolouring and deletion
                support ⌘Z, and deleting a conversation asks first. Export highlights,
                threads and answer evidence as Markdown, or save a PDF copy with real
                annotations that stay visible in Preview.
              </p>
            </div>
            <div className="bg-card rounded-3xl p-8 sm:p-12 min-h-[300px] flex flex-col justify-center">
              <h3 className="text-[28px] font-medium tracking-[-0.02em] text-primary mb-3">
                Continue on another Mac
              </h3>
              <p className="text-[16px] text-secondary leading-relaxed">
                File → Export Reading Session bundles your PDF, page and zoom,
                highlights, conversations, and completed evidence index and citation
                graph into a .cauchyreading file. Open it on another Mac to resume.
                Imported evidence is bound to the PDF and keeps its model provenance.
              </p>
            </div>
            <div className="bg-card rounded-3xl p-8 sm:p-12 min-h-[300px] flex flex-col justify-center md:col-span-2">
              <h3 className="text-[28px] font-medium tracking-[-0.02em] text-primary mb-3">
                Find a thought across your library
              </h3>
              <p className="text-[16px] text-secondary leading-relaxed max-w-3xl">
                Search highlights and conversations across every document from the
                dashboard, then jump to the result. Hide a paper from Recents without
                losing its conversations, and restore it with Show hidden. The last
                document reopens at launch; change that in Settings → Reading.
              </p>
            </div>

          </div>
        </div>
      </section>

      {/* Integrations & Setup */}
      <section className="w-full py-32 px-6 bg-background relative z-10">
        <div className="max-w-[1400px] mx-auto text-center">
          <h2 className="text-[40px] sm:text-[56px] leading-[1.1] tracking-[-0.03em] font-medium text-primary mb-6">
            Bring your own intelligence.
          </h2>
          <p className="text-[18px] text-secondary max-w-2xl mx-auto mb-16">
            {assistants.length} assistant connectors: on-device intelligence, your existing
            CLI sign-ins, or your own Anthropic, OpenAI or Gemini API key. Cauchy
            charges no subscription; provider plans and API usage are yours.{" "}
            <Link href="/setup" className={inline}>
              See the setup guide
            </Link>
            .
          </p>
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6 text-left">
            {assistants.map((assistant) => (
              <div key={assistant.id} className="bg-card p-8 sm:p-12 rounded-3xl">
                <h3 className="text-2xl font-medium text-primary mb-4">
                  <a href={assistant.url} target="_blank" rel="noopener noreferrer" className={inline}>
                    {assistant.name}
                  </a>
                </h3>
                <p className="text-[16px] text-secondary leading-relaxed">{assistant.description}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Quick FAQ */}
      <section className="w-full py-32 px-6 bg-transparent relative z-10">
        <div className="max-w-[1400px] mx-auto text-center">
          <h2 className="text-[40px] sm:text-[56px] leading-[1.1] tracking-[-0.03em] font-medium text-primary mb-16">
            Frequently Asked Questions
          </h2>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-6 max-w-[1000px] mx-auto text-left">
            <div className="bg-card p-10 rounded-3xl">
              <h3 className="text-2xl font-medium text-primary mb-4">What is Cauchy?</h3>
              <p className="text-[16px] text-secondary leading-relaxed">
                A native macOS app for reading PDFs: highlight a passage, ask about it, and
                get an answer that renders real mathematics. Built for dense technical
                textbooks, papers and problem sets.
              </p>
            </div>
            <div className="bg-card p-10 rounded-3xl">
              <h3 className="text-2xl font-medium text-primary mb-4">Where is my data stored?</h3>
              <p className="text-[16px] text-secondary leading-relaxed">
                Saved locally. Highlights, threads, viewport and thumbnails live in{" "}
                <code className="bg-[#E5E5E5] px-1.5 py-0.5 rounded text-[14px]">~/Library/Application Support/Cauchy/workspaces/</code>,
                and reference indexes in{" "}
                <code className="bg-[#E5E5E5] px-1.5 py-0.5 rounded text-[14px]">…/Cauchy/reference-index/</code>.
              </p>
            </div>
            <div className="bg-card p-10 rounded-3xl">
              <h3 className="text-2xl font-medium text-primary mb-4">Does it upload my PDFs?</h3>
              <p className="text-[16px] text-secondary leading-relaxed">
                Ask sends selected text, context and retrieved passages to your chosen
                cloud provider. Cloud reference indexing can also send page text and
                rendered page images. Choose Ollama for local processing.{" "}
                <Link href="/legal/privacy" className={inline}>Read the privacy policy</Link>.
              </p>
            </div>
            <div className="bg-card p-10 rounded-3xl">
              <h3 className="text-2xl font-medium text-primary mb-4">Why unsandboxed?</h3>
              <p className="text-[16px] text-secondary leading-relaxed">
                The Claude Code, Codex and Antigravity connectors spawn CLIs installed in
                your shell, which the{" "}
                <a href={`${REPO_URL}#sandbox`} target="_blank" rel="noopener noreferrer" className={inline}>
                  App Sandbox
                </a>{" "}
                forbids. That is also why Cauchy is not on the Mac App Store.
              </p>
            </div>
          </div>
          <div className="mt-12 max-w-[1000px] mx-auto flex flex-wrap justify-center gap-4">
            <Link href="/faq" className="bg-accent text-accent-text px-6 py-3 rounded-md text-[16px] font-medium hover:bg-accent-hover transition-colors flex items-center gap-2 w-fit">
              Read all FAQs <ArrowUpRight className="w-4 h-4" />
            </Link>
            <a
              href={`${REPO_URL}/issues`}
              target="_blank"
              rel="noopener noreferrer"
              className="bg-card text-primary px-6 py-3 rounded-md text-[16px] font-medium hover:bg-black/5 transition-colors flex items-center gap-2 w-fit"
            >
              Ask on GitHub <ArrowUpRight className="w-4 h-4" />
            </a>
          </div>
        </div>
      </section>

      {/* Secondary Hero */}
      <section className="w-full py-32 bg-background px-6 text-center flex flex-col items-center">
        <h2 className="text-[48px] sm:text-[64px] font-medium tracking-[-0.03em] leading-[1.1] text-primary max-w-[1000px] mb-2">
          Read math papers faster.
        </h2>
        <h2 className="text-[48px] sm:text-[64px] font-medium tracking-[-0.03em] leading-[1.1] text-secondary max-w-[1000px] mb-10">
          Understand proofs better.
        </h2>
        <Link href={DOWNLOAD_URL} className="bg-accent text-accent-text px-6 py-3 rounded-md text-[16px] font-medium hover:bg-accent-hover transition-colors mb-4">
          Download Cauchy
        </Link>
        <p className="text-[14px] text-secondary mb-24">
          Latest release notes on{" "}
          <a
            href={`${REPO_URL}/releases/latest`}
            target="_blank"
            rel="noopener noreferrer"
            className={inline}
          >
            GitHub
          </a>
          .
        </p>
      </section>
    </>
  );
}
