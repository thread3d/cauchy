import Link from "next/link";
import { assistants } from "@/lib/assistants";

const REPO_URL = "https://github.com/thread3d/cauchy";

const linkClass = "text-[13px] text-[#A8A29E] hover:text-white";

function External({ href, children }: { href: string; children: React.ReactNode }) {
  return (
    <a href={href} target="_blank" rel="noopener noreferrer" className={linkClass}>
      {children}
    </a>
  );
}

export default function Footer() {
  return (
    <footer className="w-full bg-[#1C1917] text-white pt-24 pb-12 px-6 mt-auto">
      <div className="max-w-[1400px] mx-auto">
        <div className="grid grid-cols-2 md:grid-cols-4 gap-8 mb-24">

          {/* Product */}
          <div className="flex flex-col gap-4">
            <span className="text-[13px] font-semibold text-white mb-2">Product</span>
            <External href={`${REPO_URL}/releases/latest/download/Cauchy.dmg`}>
              Download for macOS
            </External>
            <External href={`${REPO_URL}/releases`}>Releases</External>
            <Link href="/setup" className={linkClass}>Setup guide</Link>
            <Link href="/faq" className={linkClass}>FAQ</Link>
          </div>

          {/* Assistants */}
          <div className="flex flex-col gap-4">
            <span className="text-[13px] font-semibold text-white mb-2">Assistants</span>
            {assistants.map((assistant) => (
              <External key={assistant.id} href={assistant.url}>{assistant.name}</External>
            ))}
          </div>

          {/* Project */}
          <div className="flex flex-col gap-4">
            <span className="text-[13px] font-semibold text-white mb-2">Project</span>
            <External href={REPO_URL}>Source on GitHub</External>
            <External href={`${REPO_URL}#features`}>README</External>
            <External href={`${REPO_URL}/issues`}>Report an issue</External>
            <External href="https://github.com/mgriebling/SwiftMath">SwiftMath</External>
          </div>

          {/* Legal */}
          <div className="flex flex-col gap-4">
            <span className="text-[13px] font-semibold text-white mb-2">Legal</span>
            <Link href="/legal/privacy" className={linkClass}>Privacy Policy</Link>
            <Link href="/legal/terms" className={linkClass}>Terms of Use</Link>
            <External href={`${REPO_URL}/blob/main/LICENSE`}>MIT License</External>
          </div>

        </div>

        <div className="pt-8 border-t border-[#44403C] flex flex-col md:flex-row justify-between items-center gap-4">
          <div className="flex items-center gap-6 text-[12px] text-[#A8A29E]">
            <Link href="/legal/terms" className="hover:text-white">Terms of Use</Link>
            <Link href="/legal/privacy" className="hover:text-white">Privacy Policy</Link>
          </div>
          <div className="text-[12px] text-[#A8A29E]">
            A native macOS reader for mathematics. MIT licensed, source at{" "}
            <a href={REPO_URL} target="_blank" rel="noopener noreferrer" className="hover:text-white underline underline-offset-4">
              thread3d/cauchy
            </a>
            .
          </div>
        </div>
      </div>
    </footer>
  );
}
