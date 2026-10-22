#lang racket/base

;; Provider registry and "provider/model" routing. A model string always
;; names its provider explicitly ("openai/gpt-4o-mini"): no hidden default
;; provider, so a typo fails loudly instead of silently calling the wrong
;; vendor.

(require racket/list
         racket/string
         "error.rkt")

(provide (struct-out provider)
         current-providers
         add-provider!
         provider-ref
         provider-names
         provider-api-key
         parse-model)

;; kind is one of 'openai (OpenAI-compatible chat endpoint) or 'anthropic
;; (native Messages API). env-vars are environment variable names tried in
;; order when no explicit key is passed.
(struct provider (id base-url env-vars requires-key? kind) #:transparent)

(define built-in-providers
  (hash 'openai    (provider 'openai "https://api.openai.com/v1"
                             '("OPENAI_API_KEY") #t 'openai)
        'anthropic (provider 'anthropic "https://api.anthropic.com/v1"
                             '("ANTHROPIC_API_KEY") #t 'anthropic)
        'gemini    (provider 'gemini "https://generativelanguage.googleapis.com/v1beta/openai"
                             '("GEMINI_API_KEY" "GOOGLE_API_KEY") #t 'openai)
        'mistral   (provider 'mistral "https://api.mistral.ai/v1"
                             '("MISTRAL_API_KEY") #t 'openai)
        'deepseek  (provider 'deepseek "https://api.deepseek.com/v1"
                             '("DEEPSEEK_API_KEY") #t 'openai)
        'fireworks-ai (provider 'fireworks-ai "https://api.fireworks.ai/inference/v1"
                                '("FIREWORKS_API_KEY") #t 'openai)
        'ollama    (provider 'ollama "http://localhost:11434/v1"
                             '() #f 'openai)))

;; Immutable id->provider hash. add-provider! installs one provider into
;; the parameter's global value; parameterize for scoped extension.
(define current-providers (make-parameter built-in-providers))

(define (add-provider! p)
  (unless (provider? p)
    (raise-argument-error 'add-provider! "provider?" p))
  (current-providers (hash-set (current-providers) (provider-id p) p)))

(define (provider-names)
  (sort (hash-keys (current-providers)) symbol<?))

(define (provider-ref id)
  (define sym
    (cond [(symbol? id) id]
          [(string? id) (string->symbol id)]
          [else (raise-argument-error 'provider-ref "(or/c symbol? string?)" id)]))
  (hash-ref (current-providers) sym
            (lambda ()
              (raise-switchboard
               (format "switchboard: unknown provider ~s (known providers: ~a)"
                       id
                       (string-join (map symbol->string (provider-names)) ", "))))))

;; Explicit key wins; then env vars in declared order. Keyless providers
;; (e.g. a local Ollama) resolve to #f.
(define (provider-api-key p explicit-key)
  (or explicit-key
      (for/or ([var (in-list (provider-env-vars p))])
        (define value (getenv var))
        (and value (non-empty-string? value) value))
      (and (provider-requires-key? p)
           (raise-switchboard
            (format "switchboard: no API key for provider ~a; pass #:api-key or set one of ~a"
                    (provider-id p)
                    (provider-env-vars p))))))

;; Returns (values provider model-name). Model names may contain further
;; slashes ("fireworks-ai/accounts/x/models/y"); only the first splits.
(define (parse-model model #:provider [provider-id #f])
  (cond
    [provider-id
     (unless (string? model)
       (raise-argument-error 'parse-model "string?" model))
     (values (provider-ref provider-id) model)]
    [(and (string? model) (regexp-match #rx"^([^/]+)/(.+)$" model))
     => (lambda (match)
          (values (provider-ref (cadr match)) (caddr match)))]
    [else
     (raise-switchboard
      (format "switchboard: model ~s must look like \"provider/name\", e.g. \"openai/gpt-4o-mini\""
              model))]))
