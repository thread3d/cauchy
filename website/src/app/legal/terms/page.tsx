import Link from "next/link";

export const metadata = {
  title: "Terms of Use | Cauchy",
  description:
    "Cauchy is provided as-is, free of charge, with no warranty. You bring the models, and you carry their costs.",
};

const REPO_URL = "https://github.com/jerrydjin/cauchy";

const inline =
  "text-primary underline underline-offset-4 decoration-secondary/40 hover:decoration-primary transition-colors";

export default function TermsPage() {
  return (
    <div className="w-full max-w-3xl mx-auto px-6 py-24 sm:py-32">
      <h1 className="text-[40px] sm:text-[56px] font-medium tracking-[-0.03em] leading-[1.1] text-primary mb-8">
        Terms of Use
      </h1>

      <div className="max-w-none text-[16px] leading-relaxed text-secondary [&>p]:mb-4">
        <p className="text-secondary text-lg mb-8">
          Last updated: October 10, 2026
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">1. The Software</h2>
        <p>
          Cauchy is a macOS application distributed free of charge through{" "}
          <a href={`${REPO_URL}/releases`} target="_blank" rel="noopener noreferrer" className={inline}>
            GitHub Releases
          </a>
          . Its source is published at{" "}
          <a href={REPO_URL} target="_blank" rel="noopener noreferrer" className={inline}>
            github.com/jerrydjin/cauchy
          </a>{" "}
          under the{" "}
          <a href={`${REPO_URL}/blob/main/LICENSE`} target="_blank" rel="noopener noreferrer" className={inline}>
            MIT license
          </a>
          , which governs any reuse of the code and is the source of the warranty
          disclaimer below.
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">2. No Warranties</h2>
        <p>
          THE SOFTWARE IS PROVIDED &quot;AS IS&quot;, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">
          3. Third-Party Models and Costs
        </h2>
        <p>
          Cauchy answers questions through a provider you choose: a local model served
          by Ollama, the Claude Code, Codex or Antigravity CLIs you have signed into,
          or the Anthropic, OpenAI or Gemini API with your own key. You are solely responsible for any
          costs, rate limits, quota exhaustion or account restrictions those services
          impose.
        </p>
        <p>
          Cauchy is not affiliated with Ollama, Apple, Anthropic, OpenAI or Google. Your use of
          their services is governed by your agreements with them, and the accuracy of any
          answer is theirs, not ours &mdash; verify mathematics before you rely on it.
        </p>
        <p>
          Evidence labels record the model&apos;s declared basis and the PDF inputs
          supplied to it. Source-link checks do not prove that an answer follows from
          those inputs. AI formatting and unverified OCR candidates can contain errors;
          inspect the original PDF before relying on them.
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">
          4. Unsandboxed Execution
        </h2>
        <p>
          By installing Cauchy you acknowledge that it runs outside the macOS App Sandbox,
          which is what lets it spawn your local CLIs, and that it therefore has the same
          access to your files as your user account. The reasoning is written up in the{" "}
          <a href={`${REPO_URL}#sandbox`} target="_blank" rel="noopener noreferrer" className={inline}>
            README
          </a>
          .
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">5. Your Content</h2>
        <p>
          Your documents, highlights and threads are yours and are saved locally.
          Exports, including reading sessions containing the PDF and conversations,
          go wherever you save or share them. See
          the{" "}
          <Link href="/legal/privacy" className={inline}>
            privacy policy
          </Link>{" "}
          for what Ask and reference indexing send to a cloud provider.
        </p>

        <h2 className="text-2xl mt-12 mb-4 text-primary font-medium">6. Changes</h2>
        <p>
          These terms may be updated at any time; changes appear on this page. Questions
          go in{" "}
          <a href={`${REPO_URL}/issues`} target="_blank" rel="noopener noreferrer" className={inline}>
            a GitHub issue
          </a>
          .
        </p>
      </div>
    </div>
  );
}
