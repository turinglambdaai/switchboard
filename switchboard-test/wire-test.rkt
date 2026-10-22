#lang racket/base

(require rackunit
         switchboard)

(test-case "openai translation carries roles, content, and tool calls"
  (define wire
    (translate-openai-messages
     (list (system-message "be brief")
           (user-message "weather?")
           (assistant-message #f
                              #:tool-calls
                              (list (make-tool-call "c1" "get_weather"
                                                    (hash 'location "Paris"))))
           (tool-result-message "sunny" #:tool-call-id "c1"))))
  (check-equal? (hash-ref (car wire) 'role) "system")
  (check-equal? (hash-ref (cadr wire) 'content) "weather?")
  (define assistant (caddr wire))
  (define calls (hash-ref assistant 'tool_calls))
  (check-equal? (hash-ref (hash-ref (car calls) 'function) 'name) "get_weather")
  (check-equal? (hash-ref (cadddr wire) 'tool_call_id) "c1"))

(test-case "anthropic translation hoists system and blocks tool results"
  (define-values (system-string wire)
    (translate-anthropic-messages
     (list (system-message "be brief")
           (user-message "weather?")
           (assistant-message "checking"
                              #:tool-calls
                              (list (make-tool-call "c1" "get_weather"
                                                    (hash 'location "Paris"))))
           (tool-result-message "sunny" #:tool-call-id "c1"))))
  (check-equal? system-string "be brief")
  (check-equal? (length wire) 3)
  (check-equal? (hash-ref (car wire) 'role) "user")
  (define assistant (cadr wire))
  (define blocks (hash-ref assistant 'content))
  (check-equal? (hash-ref (car blocks) 'type) "text")
  (check-equal? (hash-ref (cadr blocks) 'type) "tool_use")
  (define tool-turn (caddr wire))
  (check-equal? (hash-ref tool-turn 'role) "user")
  (check-equal? (hash-ref (car (hash-ref tool-turn 'content)) 'type) "tool_result"))

(test-case "anthropic translation merges consecutive same-role turns"
  (define-values (_ wire)
    (translate-anthropic-messages
     (list (user-message "one")
           (tool-result-message "result" #:tool-call-id "c1"))))
  (check-equal? (length wire) 1)
  (define blocks (hash-ref (car wire) 'content))
  (check-equal? (hash-ref (car blocks) 'type) "text")
  (check-equal? (hash-ref (cadr blocks) 'type) "tool_result"))

(test-case "openai response parsing extracts content, calls, and usage"
  (define r
    (parse-openai-response
     (hash 'model "gpt-4o-mini"
           'choices
           (list (hash 'message
                       (hash 'content "Hello"
                             'tool_calls
                             (list (hash 'id "c9" 'type "function"
                                         'function
                                         (hash 'name "f"
                                               'arguments "{\"x\": 1}"))))
                       'finish_reason "tool_calls"))
           'usage (hash 'prompt_tokens 10 'completion_tokens 4 'total_tokens 14))
     "gpt-4o-mini"))
  (check-equal? (response-content r) "Hello")
  (check-equal? (length (response-tool-calls r)) 1)
  (check-equal? (tool-call-arguments (car (response-tool-calls r))) (hash 'x 1))
  (check-equal? (hash-ref (response-usage r) 'total-tokens) 14)
  (check-equal? (response-stop-reason r) "tool_calls"))

(test-case "anthropic response parsing joins text blocks"
  (define r
    (parse-anthropic-response
     (hash 'model "claude"
           'content (list (hash 'type "text" 'text "Hi")
                          (hash 'type "tool_use" 'id "c1" 'name "f"
                                'input (hash 'a 1)))
           'stop_reason "tool_use"
           'usage (hash 'input_tokens 7 'output_tokens 3))
     "claude"))
  (check-equal? (response-content r) "Hi")
  (check-equal? (tool-call-arguments (car (response-tool-calls r))) (hash 'a 1))
  (check-equal? (hash-ref (response-usage r) 'input-tokens) 7)
  (check-equal? (hash-ref (response-usage r) 'total-tokens) 10))

(test-case "error bodies raise instead of parsing"
  (check-exn exn:fail:switchboard?
             (lambda ()
               (parse-openai-response (hash 'error (hash 'message "no")) "m")))
  (check-exn exn:fail:switchboard?
             (lambda () (parse-openai-response (hash 'choices '()) "m"))))
