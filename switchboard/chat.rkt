#lang racket/base

;; Entry points. chat/ask/embed dispatch on the provider kind; everything
;; above the transport boundary is provider-independent.

(require json
         racket/flonum
         racket/list
         racket/string
         "error.rkt"
         "message.rkt"
         "provider.rkt"
         "response.rkt"
         "tool.rkt"
         "transport.rkt"
         "wire.rkt")

(provide (all-from-out "response.rkt")
         chat
         ask
         embed
         chat-with-tools)

(define (chat model
              #:messages [messages '()]
              #:tools [tools '()]
              #:tool-choice [tool-choice 'auto]
              #:temperature [temperature #f]
              #:max-tokens [max-tokens #f]
              #:system [system #f]
              #:provider [provider-override #f]
              #:api-key [api-key #f]
              #:base-url [base-url #f])
  (define-values (provider model-name) (parse-model model #:provider provider-override))
  (case (provider-kind provider)
    [(openai)
     (chat-openai provider model-name
                  #:messages messages #:tools tools
                  #:tool-choice tool-choice
                  #:temperature temperature
                  #:max-tokens max-tokens
                  #:system system
                  #:api-key api-key #:base-url base-url)]
    [(anthropic)
     (chat-anthropic provider model-name
                     #:messages messages #:tools tools
                     #:tool-choice tool-choice
                     #:max-tokens max-tokens
                     #:system system
                     #:api-key api-key #:base-url base-url)]
    [else
     (raise-switchboard
      (format "switchboard: unsupported provider kind ~s for provider ~a"
              (provider-kind provider) (provider-id provider)))]))

;; One-shot question -> answer string.
(define (ask model prompt
             #:system [system #f]
             #:temperature [temperature #f]
             #:max-tokens [max-tokens #f]
             #:provider [provider-override #f]
             #:api-key [api-key #f]
             #:base-url [base-url #f])
  (response-content
   (chat model
         #:messages prompt
         #:system system
         #:temperature temperature
         #:max-tokens max-tokens
         #:provider provider-override
         #:api-key api-key
         #:base-url base-url)))

;; Embeds a string or a list of strings; returns (listof flvector?).
(define (embed model input
               #:dimensions [dimensions #f]
               #:provider [provider-override #f]
               #:api-key [api-key #f]
               #:base-url [base-url #f])
  (define-values (provider model-name) (parse-model model #:provider provider-override))
  (unless (eq? (provider-kind provider) 'openai)
    (raise-switchboard
     (format "switchboard: provider ~a does not expose an embeddings endpoint"
             (provider-id provider))))
  (define inputs
    (cond
      [(string? input) (list input)]
      [(and (list? input) (andmap string? input)) input]
      [else (raise-argument-error 'embed "(or/c string? (listof string?))" input)]))
  (define key (provider-api-key provider api-key))
  (define base (or base-url (provider-base-url provider)))
  (define payload
    (hash-set-maybe (hash 'model model-name 'input inputs) 'dimensions dimensions))
  (define json
    ((current-post-json) (string-append base "/embeddings")
                         (bearer-headers key) payload))
  (unless (hash? json)
    (raise-switchboard "switchboard: embeddings response must be a JSON object"))
  (for/list ([item (in-list (hash-ref json 'data '()))])
    (for/flvector ([x (in-list (hash-ref item 'embedding '()))])
      (exact->inexact x))))

;; Agentic loop: run requested tool calls and feed results back until the
;; model answers without calls or max-rounds is spent.
(define (chat-with-tools model messages tools
                         #:max-rounds [max-rounds 8]
                         #:tool-choice [tool-choice 'auto]
                         #:temperature [temperature #f]
                         #:max-tokens [max-tokens #f]
                         #:system [system #f]
                         #:provider [provider-override #f]
                         #:api-key [api-key #f]
                         #:base-url [base-url #f])
  (let loop ([conversation (normalize-messages messages)]
             [fuel max-rounds])
    (define r
      (chat model
            #:messages conversation
            #:tools tools
            #:tool-choice tool-choice
            #:temperature temperature
            #:max-tokens max-tokens
            #:system system
            #:provider provider-override
            #:api-key api-key
            #:base-url base-url))
    (define calls (response-tool-calls r))
    (if (or (null? calls) (<= fuel 1))
        r
        (loop (append conversation
                      (cons (assistant-message (response-content r)
                                               #:tool-calls calls)
                            (for/list ([result (in-list (run-tool-calls tools calls))])
                              (tool-result-message
                               (tool-result-output result)
                               #:tool-call-id (tool-result-call-id result)))))
              (sub1 fuel)))))

;; ---- OpenAI-compatible path -------------------------------------------

(define (chat-openai provider model-name
                     #:messages messages
                     #:tools tools
                     #:tool-choice tool-choice
                     #:temperature temperature
                     #:max-tokens max-tokens
                     #:system system
                     #:api-key api-key
                     #:base-url base-url)
  (define key (provider-api-key provider api-key))
  (define url
    (string-append (or base-url (provider-base-url provider)) "/chat/completions"))
  (define wire-messages
    (translate-openai-messages
     (if system
         (cons (system-message system) (normalize-messages messages))
         messages)))
  (define payload
    (hash-set-maybe
     (hash-set-maybe
      (hash-set-maybe
       (hash-set-maybe
        (hash 'model model-name
              'messages wire-messages
              'stream #f)
        'tools (and (pair? tools) (translate-openai-tools tools)))
       'tool_choice (and (pair? tools) (tool-choice-openai tool-choice)))
      'temperature temperature)
     'max_tokens max-tokens))
  (send-openai url (bearer-headers key) payload model-name))

;; Newer OpenAI models reject max_tokens and demand max_completion_tokens;
;; retry once with the renamed key when the 400 body says so. The renamed
;; payload no longer carries max_tokens, so a second mismatch cannot loop.
(define (send-openai url headers payload model-name)
  (define json
    (with-handlers
      ([exn:fail:switchboard:api?
        (lambda (e)
          (if (needs-max-completion-tokens? e payload)
              ((current-post-json)
               url headers
               (hash-set (hash-remove payload 'max_tokens)
                         'max_completion_tokens
                         (hash-ref payload 'max_tokens)))
              (raise e)))])
      ((current-post-json) url headers payload)))
  (parse-openai-response json model-name))

(define (needs-max-completion-tokens? e payload)
  (and (exn:fail:switchboard:api? e)
       (equal? (exn:fail:switchboard:api-status e) 400)
       (hash-has-key? payload 'max_tokens)
       (let ([body (exn:fail:switchboard:api-body e)])
         (and (string? body)
              (regexp-match? #rx"max_completion_tokens" body)))))

;; ---- Anthropic path ----------------------------------------------------

(define (chat-anthropic provider model-name
                        #:messages messages
                        #:tools tools
                        #:tool-choice tool-choice
                        #:max-tokens max-tokens
                        #:system system
                        #:api-key api-key
                        #:base-url base-url)
  (define key (provider-api-key provider api-key))
  (unless key
    (raise-switchboard "switchboard: the Anthropic API requires an API key"))
  (define url
    (string-append (or base-url (provider-base-url provider)) "/messages"))
  (define-values (system-string wire-messages)
    (translate-anthropic-messages messages #:system system))
  (define payload
    (hash-set-maybe
     (hash-set-maybe
      (hash-set-maybe
       (hash 'model model-name
             'max_tokens (or max-tokens 1024)
             'messages wire-messages)
       'system system-string)
      'tools (and (pair? tools) (translate-anthropic-tools tools)))
     'tool_choice (and (pair? tools) (tool-choice-anthropic tool-choice))))
  (define headers
    (hash-set* (hasheq)
               'x-api-key key
               'anthropic-version "2023-06-01"))
  (parse-anthropic-response ((current-post-json) url headers payload) model-name))

;; ---- helpers -----------------------------------------------------------

(define (hash-set-maybe h k v)
  (if v (hash-set h k v) h))

(define (tool-choice-openai choice)
  (case choice
    [(auto) "auto"]
    [(none) "none"]
    [(required) "required"]
    [else (raise-argument-error 'chat "#:tool-choice in {'auto 'none 'required}" choice)]))

(define (tool-choice-anthropic choice)
  (case choice
    [(auto) (hash 'type "auto")]
    [(none) (hash 'type "none")]
    [(required) (hash 'type "any")]
    [else (raise-argument-error 'chat "#:tool-choice in {'auto 'none 'required}" choice)]))
