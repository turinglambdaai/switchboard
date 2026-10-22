# Changelog

## 0.1.0 — 2026-10-22

- Provider registry with explicit `provider/model` routing; bare model names are rejected.
- Uniform chat surface over OpenAI-compatible endpoints (OpenAI, Gemini, Mistral, DeepSeek, Ollama, self-registered) and a native Anthropic Messages adapter.
- Tools are Racket procedures; structured `tool-call`/`tool-result` values and an agent loop (`chat-with-tools`) whose tool failures feed the model instead of aborting.
- `embed` returning flonum vectors in input order.
- Structured exception hierarchy, including a distinct context-window subtype.
- Injectable HTTP transport (`current-post-json`); no hidden retries.
