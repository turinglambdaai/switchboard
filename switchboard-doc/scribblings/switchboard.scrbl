#lang scribble/manual

@title{Switchboard}
@author{TurLamAI}

Public module: @tt{switchboard}

Switchboard is a uniform client for hosted LLM APIs: one chat surface, one
tool-calling surface, one embedding surface, one exception hierarchy — every
model addressed as a @tt{"provider/model"} string. OpenAI-compatible endpoints
(OpenAI, Gemini, Mistral, DeepSeek, Ollama, anything else registered) share one
code path; Anthropic gets a native adapter for its Messages API.

Switchboard is not an agent framework, a prompt library, or a vector store. It
owns exactly the boundary between Racket code and model APIs, and it performs
no hidden work: no retries, no hidden default provider, no implicit model.

@section{Provider routing}

@verbatim{
(provider id base-url env-vars requires-key? kind) -> provider?
  id           : symbol?
  base-url     : string?
  env-vars     : (listof string?)
  requires-key? : boolean?
  kind         : (or/c 'openai 'anthropic)
}

Built-in providers: @tt{openai}, @tt{anthropic}, @tt{gemini}, @tt{mistral},
@tt{deepseek}, @tt{ollama}. A model string always names its provider
explicitly, and a bare model name is rejected — a typo should fail loudly,
never silently route to some default vendor.

@verbatim{
(parse-model model #:provider provider-id) -> (values provider? string?)
(provider-ref id) -> provider?
(provider-names) -> (listof symbol?)
(add-provider! p) -> void?
(provider-api-key p explicit-key) -> (or/c string? #f)
}

API keys resolve in one order: the explicit @tt{#:api-key} argument, then the
provider's environment variables in declared order, then failure for providers
that require a key. Keyless local providers (@tt{ollama}) resolve to
@racket[#f].

Register any other OpenAI-compatible endpoint by adding one provider; the chat
path is shared:

@racketblock[
(add-provider!
 (provider 'groq "https://api.groq.com/openai/v1"
           '("GROQ_API_KEY") #t 'openai))
(ask "groq/llama-3.1-8b-instant" "Say hi.")
]

@section{Messages}

@verbatim{
(message role content tool-calls tool-call-id name) -> message?
  role       : (or/c 'system 'user 'assistant 'tool)
  content    : (or/c string? #f)
  tool-calls : (listof tool-call?)
  tool-call-id : (or/c string? #f)
  name       : (or/c string? #f)
}

Constructors: @tt{system-message}, @tt{user-message},
@tt{assistant-message}, @tt{tool-result-message}. At the edge,
@tt{normalize-messages} also accepts bare strings (user messages) and
@racket[(list role content)] forms; everything downstream sees structs only.
An assistant message must carry content or tool calls; a tool result must
carry its @tt{#:tool-call-id}. Wire formats never leak into user code.

@section{Tools}

@verbatim{
(make-tool name description parameters procedure) -> tool?
  name        : (or/c symbol? string?)
  description : string?
  parameters  : (listof parameter-spec?)
  procedure   : (-> (hash/c symbol? json+jsexpr?) any/c)
(parameter name type description
           #:required required? #:enum enumeration) -> parameter-spec?
}

A tool is an ordinary Racket procedure of one hash argument (symbol keys,
decoded JSON). Non-string return values are formatted with @tt{~a}.

Execution never throws. @tt{run-tool-calls} returns one @tt{tool-result} per
call, and every failure — unknown tool, missing required argument, a crashing
procedure — becomes an @tt{"Error: ..."} output string. Tool failures are the
model's feedback channel; one bad call must not abort an agent loop.

@section{Chat}

@verbatim{
(chat model
      #:messages messages #:tools tools #:tool-choice choice
      #:temperature temperature #:max-tokens max-tokens #:system system
      #:provider provider-id #:api-key api-key #:base-url base-url)
 -> response?
(ask model prompt ...) -> string?
(chat-with-tools model messages tools #:max-rounds rounds ...) -> response?
(response content tool-calls stop-reason model usage raw) -> response?
}

@tt{chat} returns the full response: content, any tool calls (returned, never
executed — run them yourself with @tt{run-tool-calls}, or let
@tt{chat-with-tools} run the request/execute/reply loop until the model
answers without calls or @tt{#:max-rounds} is spent), the stop reason, token
usage, and the raw JSON body.

The uniform surface keeps only options every provider honors the same way.
Anthropic receives @tt{max-tokens} with a 1024 default; hidden per-vendor
extras belong in a dedicated adapter, not in the shared API.

@section{Embeddings}

@verbatim{
(embed model input
       #:dimensions dimensions #:provider provider-id
       #:api-key api-key #:base-url base-url) -> (listof flvector?)
  input : (or/c string? (listof string?))
}

Embeddings run through the shared OpenAI-compatible endpoint and come back as
flonum vectors in input order. Providers without an embeddings endpoint raise.

@section{Errors}

@verbatim{
exn:fail:switchboard
└── exn:fail:switchboard:api          (fields: status body)
    ├── exn:fail:switchboard:auth             401, 403
    ├── exn:fail:switchboard:rate-limit       429
    ├── exn:fail:switchboard:not-found        404
    └── exn:fail:switchboard:context-window   400 blaming the context
}

Every provider failure crosses this boundary as one of these subtypes, so
callers dispatch on structure instead of parsing provider error strings. A
400 whose body blames the context window is its own subtype because the
recovery (trim the conversation and retry) differs from every other 400.

@section{The transport boundary}

@verbatim{
(current-post-json) -> (-> string? (hash/c symbol? string?) jsexpr? jsexpr?)
}

All traffic flows through this parameter. Tests stub it and never touch the
network; local gateways swap in at one place. Switchboard performs no hidden
retries — retry and backoff policy lives above the library, where it can be
owned and observed.
