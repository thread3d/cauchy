// Keep this catalog aligned with Cauchy/Models/AssistantConnector.swift.
// Product pages and navigation share it so connector lists stay consistent.
export const assistants = [
  {
    id: "ollama",
    name: "Ollama",
    url: "https://ollama.com",
    description:
      "Run open models locally through Ollama. Start the server, pull a chat model, and Cauchy discovers it automatically; no key and no cloud are needed. Ask and reference indexing use the local model by default.",
  },
  {
    id: "claudeCode",
    name: "Claude Code",
    url: "https://docs.claude.com/en/docs/claude-code/overview",
    description:
      "Connect your Claude account in Cauchy’s Settings. The guided flow installs the CLI, handles provider sign-in, and checks the connection. Choose Fable, Opus, Sonnet or Haiku for answers.",
  },
  {
    id: "codex",
    name: "Codex",
    url: "https://github.com/openai/codex",
    description:
      "Connect your ChatGPT account in Settings using the guided CLI installation and sign-in. The model picker offers GPT-6 Astra, Sol and Luna.",
  },
  {
    id: "antigravity",
    name: "Antigravity",
    url: "https://antigravity.google/",
    description:
      "Connect your Google account in Settings. Cauchy uses the agy CLI and the model you choose with /model inside agy; it does not show a separate model picker.",
  },
  {
    id: "anthropicAPI",
    name: "Anthropic API",
    url: "https://platform.claude.com/settings/keys",
    description:
      "Add your own Anthropic key under Settings → Your API keys. Choose Fable, Opus, Sonnet or Haiku. The key lives in your macOS Keychain and API usage is billed separately by Anthropic.",
  },
  {
    id: "openaiAPI",
    name: "OpenAI API",
    url: "https://platform.openai.com/api-keys",
    description:
      "Add your own OpenAI key under Settings → Your API keys. Choose GPT-6 Astra, Sol or Luna. The key lives in your macOS Keychain and API usage is billed separately from your ChatGPT plan.",
  },
  {
    id: "gemini",
    name: "Gemini API",
    url: "https://aistudio.google.com/apikey",
    description:
      "Create a key in Google AI Studio and add it under Settings → Your API keys. Pro, Flash and Flash-Lite models are available. The key lives in your macOS Keychain and usage is billed to your Google account.",
  },
] as const;
