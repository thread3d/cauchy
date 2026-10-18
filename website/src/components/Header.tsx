import Link from "next/link";

export default function Header() {
  return (
    <header className="w-full bg-background/90 backdrop-blur-md sticky top-0 z-50">
      <div className="max-w-[1400px] mx-auto px-6 lg:px-10 h-[72px] flex items-center justify-between">
        <div className="flex items-center gap-8">
          <Link href="/" className="flex items-center gap-2">
            <span className="text-xl font-medium tracking-tight text-primary">cauchy</span>
          </Link>

          <nav className="hidden lg:flex items-center gap-6 text-[15px] font-medium text-primary">
            <Link href="/setup" className="hover:opacity-60 transition-opacity flex items-center gap-1">
              Setup
            </Link>
            <Link href="/faq" className="hover:opacity-60 transition-opacity flex items-center gap-1">
              FAQ
            </Link>
            <a
              href="https://github.com/thread3d/cauchy/releases"
              target="_blank"
              rel="noopener noreferrer"
              className="hover:opacity-60 transition-opacity"
            >
              Releases
            </a>
            <a
              href="https://github.com/thread3d/cauchy"
              target="_blank"
              rel="noopener noreferrer"
              className="hover:opacity-60 transition-opacity"
            >
              GitHub
            </a>
          </nav>
        </div>

        <div className="flex items-center gap-6">
          <Link
            href="https://github.com/thread3d/cauchy/releases/latest/download/Cauchy.dmg"
            className="bg-accent text-accent-text px-5 py-2.5 rounded-md text-[15px] font-medium hover:bg-accent-hover transition-colors"
          >
            Get Cauchy
          </Link>
        </div>
      </div>
    </header>
  );
}
