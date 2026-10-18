import type { Metadata } from "next";
import { Manrope, Geist_Mono } from "next/font/google";
import "./globals.css";
import Header from "@/components/Header";
import Footer from "@/components/Footer";

const manrope = Manrope({
  variable: "--font-manrope",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

const SITE_URL = "https://cauchy-wine.vercel.app";
const DESCRIPTION =
  "A native macOS PDF reader for mathematics with evidence-bound AI answers, source-first reference previews, library search and portable reading sessions. Use local models through Ollama, Claude Code, Codex, Antigravity, or your own Anthropic, OpenAI or Gemini API key.";

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: "Cauchy — a PDF reader that talks back",
  description: DESCRIPTION,
  applicationName: "Cauchy",
  keywords: [
    "PDF reader",
    "macOS",
    "mathematics",
    "LaTeX",
    "Ollama",
    "Claude Code",
    "Codex",
    "Gemini",
    "Anthropic API",
    "OpenAI API",
    "Antigravity",
    "reading sessions",
    "library search",
    "papers",
    "theorems",
  ],
  openGraph: {
    type: "website",
    url: SITE_URL,
    siteName: "Cauchy",
    title: "Cauchy — a PDF reader that talks back",
    description: DESCRIPTION,
    images: [{ url: "/app-screenshot.png", width: 3300, height: 2168, alt: "Cauchy showing a highlighted Cayley–Hamilton theorem and a conversation with answer evidence and PDF source links" }],
  },
  twitter: {
    card: "summary_large_image",
    title: "Cauchy — a PDF reader that talks back",
    description: DESCRIPTION,
    images: [{ url: "/app-screenshot.png", alt: "Cauchy showing a highlighted Cayley–Hamilton theorem and a conversation with answer evidence and PDF source links" }],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${manrope.variable} ${geistMono.variable} h-full antialiased scroll-smooth`}
    >
      <body className="min-h-full flex flex-col bg-background text-foreground font-sans selection:bg-accent selection:text-foreground">
        <Header />
        <main className="flex-1 flex flex-col items-center w-full relative">
          {children}
        </main>
        <Footer />
      </body>
    </html>
  );
}
