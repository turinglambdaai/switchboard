#lang racket/base

;; Wire formats. These translations are exposed on purpose: adding a
;; provider kind means reusing them, not reopening the core.

(require json
         racket/list
         racket/string
         "error.rkt"
         "message.rkt"
         "response.rkt"
         "tool.rkt")

(provide translate-openai-messages
         translate-openai-tools
         translate-anthropic-messages
         translate-anthropic-tools
         parse-openai-response
         parse-anthropic-response
         json-null->false)

;; ---- OpenAI-compatible -------------------------------------------------

(define (tool-call->openai-json call)
  (hash 'id (tool-call-id call)
        'type "function"
        'function (hash 'name (tool-call-name call)
                        'arguments (or (tool-call-raw-arguments call)
                                       (jsexpr->string (tool-call-arguments call))))))

(define (message->openai-json m)
  (define base (hash 'role (symbol->string (message-role m))))
  (define with-content
    (if (message-content m)
        (hash-set base 'content (message-content m))
        base))
  (define with-calls
    (if (pair? (message-tool-calls m))
        (hash-set with-content 'tool_calls
                  (map tool-call->openai-json (message-tool-calls m)))
        with-content))
  (define with-call-id
    (if (message-tool-call-id m)
        (hash-set with-calls 'tool_call_id (message-tool-call-id m))
        with-calls))
  (if (message-name m)
      (hash-set with-call-id 'name (message-name m))
      with-call-id))

(define (translate-openai-messages messages)
  (map message->openai-json (normalize-messages messages)))

(define (translate-openai-tools tools)
  (for/list ([t (in-list tools)])
    (tool-json-schema t 'openai)))

;; ---- Anthropic ---------------------------------------------------------

;; system lives at the top level, not as a message; tool results travel as
;; user-side tool_result blocks; consecutive same-role turns must merge or
;; the API rejects the request.
(define (translate-anthropic-messages messages #:system [extra-system #f])
  (define normalized (normalize-messages messages))
  (define system-parts
    (append (for/list ([m (in-list normalized)]
                       #:when (eq? (message-role m) 'system))
              (message-content m))
            (if extra-system (list extra-system) '())))
  (define system-string
    (and (pair? system-parts) (string-join system-parts "\n\n")))
  (define wire
    (for/list ([m (in-list normalized)]
               #:unless (eq? (message-role m) 'system))
      (cond
        [(eq? (message-role m) 'tool)
         (hash 'role "user"
               'content (list (hash 'type "tool_result"
                                    'tool_use_id (message-tool-call-id m)
                                    'content (or (message-content m) ""))))]
        [(eq? (message-role m) 'assistant)
         (hash 'role "assistant"
               'content (anthropic-assistant-blocks m))]
        [else
         (hash 'role "user" 'content (or (message-content m) ""))])))
  (values system-string (merge-consecutive-runs wire)))

(define (translate-anthropic-tools tools)
  (for/list ([t (in-list tools)])
    (tool-json-schema t 'anthropic)))

(define (anthropic-assistant-blocks m)
  (define blocks
    (append (if (message-content m)
                (list (hash 'type "text" 'text (message-content m)))
                '())
            (for/list ([call (in-list (message-tool-calls m))])
              (hash 'type "tool_use"
                    'id (tool-call-id call)
                    'name (tool-call-name call)
                    'input (tool-call-arguments call)))))
  (when (null? blocks)
    (raise-switchboard
     "switchboard: an assistant message needs content or tool calls"))
  blocks)

(define (merge-consecutive-runs wire)
  (let loop ([rest wire] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [(and (pair? acc)
            (string=? (hash-ref (car acc) 'role)
                      (hash-ref (car rest) 'role)))
       (define merged (merge-wire-messages (car acc) (car rest)))
       (loop (cdr rest) (cons merged (cdr acc)))]
      [else (loop (cdr rest) (cons (car rest) acc))])))

(define (merge-wire-messages left right)
  (hash 'role (hash-ref left 'role)
        'content (append (wire-content-blocks left)
                         (wire-content-blocks right))))

(define (wire-content-blocks m)
  (define content (hash-ref m 'content))
  (if (string? content)
      (list (hash 'type "text" 'text content))
      content))

;; ---- Response parsing --------------------------------------------------

(define (json-null->false v)
  (if (eq? v 'null) #f v))

(define (blocks->text content)
  (cond
    [(string? content) content]
    [(list? content)
     (define texts
       (filter-map (lambda (block)
                     (and (hash? block) (hash-ref block 'text #f)))
                   content))
     (and (pair? texts) (string-join texts ""))]
    [else #f]))

(define (checked-response-json json who)
  (unless (hash? json)
    (raise-switchboard (format "switchboard: ~a response must be a JSON object, got ~s" who json)))
  (when (hash-has-key? json 'error)
    (raise-switchboard
     (format "switchboard: provider error: ~s" (hash-ref json 'error)))))

(define (parse-openai-response json model-name)
  (checked-response-json json "chat")
  (define choices (hash-ref json 'choices '()))
  (when (null? choices)
    (raise-switchboard (format "switchboard: chat response has no choices: ~s" json)))
  (define choice (car choices))
  (define message-json (hash-ref choice 'message (hash)))
  (define tool-calls
    (for/list ([call-json (in-list (hash-ref message-json 'tool_calls '()))])
      (define function (hash-ref call-json 'function (hash)))
      (define arguments (hash-ref function 'arguments "{}"))
      (make-tool-call (hash-ref call-json 'id "")
                      (hash-ref function 'name "")
                      (if (hash? arguments) arguments (format "~a" arguments)))))
  (response (blocks->text (json-null->false (hash-ref message-json 'content #f)))
            tool-calls
            (json-null->false (hash-ref choice 'finish_reason #f))
            (hash-ref json 'model model-name)
            (openai-usage json)
            json))

(define (openai-usage json)
  (define usage (hash-ref json 'usage #f))
  (and (hash? usage)
       (hash 'input-tokens (hash-ref usage 'prompt_tokens #f)
             'output-tokens (hash-ref usage 'completion_tokens #f)
             'total-tokens (hash-ref usage 'total_tokens #f))))

(define (parse-anthropic-response json model-name)
  (checked-response-json json "Anthropic chat")
  (define blocks (hash-ref json 'content '()))
  (define content
    (let ([texts (for/list ([block (in-list blocks)]
                            #:when (and (hash? block)
                                        (equal? (hash-ref block 'type "") "text")
                                        (hash-ref block 'text #f)))
                   (hash-ref block 'text))])
      (and (pair? texts) (string-join texts ""))))
  (define tool-calls
    (for/list ([block (in-list blocks)]
               #:when (and (hash? block)
                           (equal? (hash-ref block 'type "") "tool_use")))
      (make-tool-call (hash-ref block 'id "")
                      (hash-ref block 'name "")
                      (hash-ref block 'input (hash)))))
  (define usage-json (hash-ref json 'usage #f))
  (define usage
    (and (hash? usage-json)
         (let ([in (hash-ref usage-json 'input_tokens #f)]
               [out (hash-ref usage-json 'output_tokens #f)])
           (hash 'input-tokens in
                 'output-tokens out
                 'total-tokens (and in out (+ in out))))))
  (response content
            tool-calls
            (json-null->false (hash-ref json 'stop_reason #f))
            (hash-ref json 'model model-name)
            usage
            json))
