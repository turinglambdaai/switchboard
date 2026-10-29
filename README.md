# Switchboard

**One call, every provider — chat, tools, and embeddings behind a single Racket API.**

[![CI](https://github.com/turlamai/switchboard/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/switchboard/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

**English** · [中文](README.zh-CN.md)

Switchboard is the LLM access layer for Racket programs. Every model is addressed as a `"provider/model"` string, every provider speaks through one chat/tool/embedding surface, and every failure surfaces as one structured exception hierarchy. OpenAI-compatible endpoints (OpenAI, Gemini, Mistral, DeepSeek, Ollama, anything you register) share one code path; Anthropic has a native adapter for its Messages API.

Switchboard is not an agent framework, a prompt library, or a vector store. It owns exactly the boundary between your code and hosted model APIs — and performs no hidden work there: no retries, no hidden default provider, no implicit model.

## Quick start

```racket
(require switchboard)

(ask "openai/gpt-4o-mini" "What is 2 + 2?")
;; => "2 + 2 equals 4."
```

Local runtimes need no key:

```racket
(ask "ollama/qwen3:1.7b" "Name three sorting algorithms.")
```

Any other OpenAI-compatible endpoint is one registration away:

```racket
(add-provider!
 (provider 'groq "https://api.groq.com/openai/v1"
           '("GROQ_API_KEY") #t 'openai))
(ask "groq/llama-3.1-8b-instant" "Say hi.")
```

## Tools are Racket functions

```racket
(define weather
  (make-tool "get_weather" "Current weather for a city"
             (list (parameter 'location "string" "City name"))
             (lambda (args)
               (format "Sunny, 22C in ~a" (hash-ref args 'location)))))

(response-content
 (chat-with-tools "openai/gpt-4o-mini"
                  (list (user-message "What's the weather in Paris?"))
                  (list weather)))
```

The model's calls come back as structured `tool-call` values; `chat-with-tools` executes them and feeds the results back until the model answers. Tool failures — unknown tool, missing argument, a crashing procedure — become `"Error: ..."` strings for the model, never an exception in your loop.

## Embeddings

```racket
(embed "openai/text-embedding-3-small" '("hello" "world"))
;; => '(flvector ... flvector ...)
```

## Errors you can dispatch on

```
exn:fail:switchboard
└── exn:fail:switchboard:api          (status, body)
    ├── exn:fail:switchboard:auth             401, 403
    ├── exn:fail:switchboard:rate-limit       429
    ├── exn:fail:switchboard:not-found        404
    └── exn:fail:switchboard:context-window   400 blaming the context
```

Retry and backoff policy is yours: Switchboard raises structured exceptions and performs no hidden retries.

## Design notes

- **Explicit routing.** A model string always names its provider; bare names are rejected so a typo fails loudly instead of silently calling the wrong vendor.
- **Injectable transport.** All HTTP flows through one parameter, `current-post-json`. Tests run without network; local gateways swap in at one place.
- **Stable shapes.** Messages are structs with symbol roles; wire formats never leak into user code. `wire.rkt` is public on purpose for anyone adding a provider kind.
- **Structured failures only.** Every provider error crosses the boundary as a switchboard exception subtype.

## Development

```sh
raco pkg install --auto --name switchboard .
raco test -p switchboard
raco setup --check-pkg-deps switchboard
```

CI runs the test suite on Linux, Windows, and macOS against Racket 9.0 and 9.3, then checks declared dependencies and builds the reference manual.

## License

[Apache-2.0](LICENSE)
