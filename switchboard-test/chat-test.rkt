#lang racket/base

;; Behavioral tests over a stubbed transport: the full chat, tool loop, and
;; embedding paths run without network.

(require racket/flonum
         racket/match
         rackunit
         switchboard)

(define openai-answer
  (hash 'model "gpt-4o-mini"
        'choices (list (hash 'message (hash 'content "Hello!")
                             'finish_reason "stop"))
        'usage (hash 'prompt_tokens 1 'completion_tokens 1 'total_tokens 2)))

;; Runs THUNK with current-post-json answering from RESPONSES in order;
;; returns (values thunk-result (list (list url headers payload) ...)).
(define (capture-transport responses thunk)
  (define calls (box '()))
  (define queue (box responses))
  (define result
    (parameterize ([current-post-json
                    (lambda (url headers payload)
                      (set-box! calls (cons (list url headers payload)
                                            (unbox calls)))
                      (define remaining (unbox queue))
                      (cond
                        [(null? remaining) (error "unexpected extra HTTP call")]
                        [else
                         (define next (car remaining))
                         (set-box! queue (cdr remaining))
                         (if (exn? next) (raise next) next)]))])
      (thunk)))
  (values result (reverse (unbox calls))))

(define (api-error status body)
  (exn:fail:switchboard:api "provider failure"
                            (current-continuation-marks)
                            status body))

(define (rate-limit-error)
  (exn:fail:switchboard:rate-limit "provider failure"
                                   (current-continuation-marks)
                                   429
                                   "slow down"))

(test-case "chat posts to the provider's chat endpoint and parses the answer"
  (define-values (result calls)
    (capture-transport
     (list openai-answer)
     (lambda ()
       (chat "openai/gpt-4o-mini"
             #:messages "hi"
             #:api-key "test-key"))))
  (check-equal? (response-content result) "Hello!")
  (check-equal? (length calls) 1)
  (match-define (list url headers payload) (car calls))
  (check-equal? url "https://api.openai.com/v1/chat/completions")
  (check-equal? (hash-ref headers 'authorization) "Bearer test-key")
  (check-equal? (hash-ref payload 'model) "gpt-4o-mini")
  (check-equal? (hash-ref payload 'messages)
                (list (hash 'role "user" 'content "hi")))
  (check-false (hash-has-key? payload 'tools)))

(test-case "a system message goes first on the wire"
  (define-values (_ calls)
    (capture-transport
     (list openai-answer)
     (lambda ()
       (chat "openai/gpt-4o-mini"
             #:messages "hi"
             #:system "be brief"
             #:api-key "test-key"))))
  (check-equal? (hash-ref (caddr (car calls)) 'messages)
                (list (hash 'role "system" 'content "be brief")
                      (hash 'role "user" 'content "hi"))))

(test-case "chat with tools declares them in the payload"
  (define weather
    (make-tool "get_weather" "Weather"
               (list (parameter 'location "string" "City"))
               (lambda (args) "sunny")))
  (define-values (_ calls)
    (capture-transport
     (list openai-answer)
     (lambda ()
       (chat "openai/gpt-4o-mini"
             #:messages "hi"
             #:tools (list weather)
             #:api-key "test-key"))))
  (define payload (caddr (car calls)))
  (define tools (hash-ref payload 'tools))
  (check-equal? (hash-ref (hash-ref (car tools) 'function) 'name)
                "get_weather")
  (check-equal? (hash-ref payload 'tool_choice) "auto"))

(test-case "anthropic chat uses the native endpoint and headers"
  (define anthropic-answer
    (hash 'model "claude"
          'content (list (hash 'type "text" 'text "Bonjour"))
          'stop_reason "end_turn"
          'usage (hash 'input_tokens 2 'output_tokens 2)))
  (define-values (result calls)
    (capture-transport
     (list anthropic-answer)
     (lambda ()
       (chat "anthropic/claude"
             #:messages "salut"
             #:api-key "test-key"))))
  (check-equal? (response-content result) "Bonjour")
  (match-define (list url headers payload) (car calls))
  (check-equal? url "https://api.anthropic.com/v1/messages")
  (check-equal? (hash-ref headers 'x-api-key) "test-key")
  (check-equal? (hash-ref headers 'anthropic-version) "2023-06-01")
  (check-equal? (hash-ref payload 'max_tokens) 1024))

(test-case "the tool loop executes calls and feeds results back"
  (define weather
    (make-tool "get_weather" "Weather"
               (list (parameter 'location "string" "City"))
               (lambda (args)
                 (format "sunny in ~a" (hash-ref args 'location)))))
  (define tool-call-answer
    (hash 'model "gpt-4o-mini"
          'choices
          (list (hash 'finish_reason "tool_calls"
                      'message
                      (hash 'content #f
                            'tool_calls
                            (list (hash 'id "c1" 'type "function"
                                        'function
                                        (hash 'name "get_weather"
                                              'arguments "{\"location\": \"Paris\"}"))))))))
  (define-values (result calls)
    (capture-transport
     (list tool-call-answer openai-answer)
     (lambda ()
       (chat-with-tools "openai/gpt-4o-mini"
                        (list (user-message "weather in Paris?"))
                        (list weather)
                        #:api-key "test-key"))))
  (check-equal? (response-content result) "Hello!")
  (check-equal? (length calls) 2)
  (define second-messages (hash-ref (caddr (cadr calls)) 'messages))
  (check-equal? (length second-messages) 3)
  (check-equal? (hash-ref (caddr second-messages) 'tool_call_id) "c1")
  (check-equal? (hash-ref (caddr second-messages) 'content) "sunny in Paris"))

(test-case "embeddings parse into flvectors in order"
  (define-values (result calls)
    (capture-transport
     (list (hash 'data (list (hash 'embedding '(1 2))
                             (hash 'embedding '(3 4)))))
     (lambda ()
       (embed "openai/text-embedding-3-small" '("a" "b")
              #:api-key "test-key"))))
  (check-equal? (length result) 2)
  (check-true (flvector? (car result)))
  (check-equal? (flvector-ref (car result) 0) 1.0)
  (check-equal? (flvector-ref (cadr result) 1) 4.0)
  (check-equal? (hash-ref (caddr (car calls)) 'model)
                "text-embedding-3-small"))

(test-case "embeddings reject providers without an embeddings endpoint"
  (check-exn exn:fail:switchboard?
             (lambda ()
               (embed "anthropic/claude" "x" #:api-key "test-key"))))

(test-case "a max_completion_tokens 400 retries once with the renamed key"
  (define-values (_ calls)
    (capture-transport
     (list (api-error 400 "use max_completion_tokens instead")
           openai-answer)
     (lambda ()
       (chat "openai/gpt-4o-mini"
             #:messages "hi"
             #:max-tokens 50
             #:api-key "test-key"))))
  (check-equal? (length calls) 2)
  (define retry-payload (caddr (cadr calls)))
  (check-false (hash-has-key? retry-payload 'max_tokens))
  (check-equal? (hash-ref retry-payload 'max_completion_tokens) 50))

(test-case "other 400s surface immediately without a retry"
  (check-exn exn:fail:switchboard:api?
             (lambda ()
               (capture-transport
                (list (api-error 400 "bad model name"))
                (lambda ()
                  (chat "openai/gpt-4o-mini"
                        #:messages "hi"
                        #:max-tokens 50
                        #:api-key "test-key"))))))

(test-case "transport failures surface as structured exceptions"
  (check-exn exn:fail:switchboard:rate-limit?
             (lambda ()
               (capture-transport
                (list (rate-limit-error))
                (lambda ()
                  (chat "openai/gpt-4o-mini"
                        #:messages "hi"
                        #:api-key "test-key"))))))
