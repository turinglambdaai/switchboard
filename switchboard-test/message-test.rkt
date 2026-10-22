#lang racket/base

(require rackunit
         switchboard)

(test-case "a bare string is a user message"
  (check-equal? (normalize-messages "hi")
                (list (user-message "hi"))))

(test-case "role strings normalize to symbols"
  (define m (car (normalize-messages (list (list "USER" "hello")))))
  (check-equal? (message-role m) 'user))

(test-case "constructors produce normalized structs"
  (check-equal? (normalize-messages
                 (list (system-message "be brief")
                       (user-message "hi")
                       (assistant-message "hello")
                       (tool-result-message "42" #:tool-call-id "call_1")))
                (list (message 'system "be brief" '() #f #f)
                      (message 'user "hi" '() #f #f)
                      (message 'assistant "hello" '() #f #f)
                      (message 'tool "42" '() "call_1" #f))))

(test-case "unknown roles fail"
  (check-exn exn:fail:switchboard?
             (lambda () (normalize-messages (list (list 'wizard "hi"))))))

(test-case "an assistant message needs content or tool calls"
  (check-exn exn:fail:switchboard?
             (lambda () (normalize-messages (list (assistant-message #f))))))

(test-case "a tool result needs its call id"
  (check-exn exn:fail:switchboard?
             (lambda () (normalize-messages (list (message 'tool "42" '() #f #f))))))

(test-case "garbage input fails with a readable error"
  (check-exn exn:fail:switchboard? (lambda () (normalize-messages 42)))
  (check-exn exn:fail:switchboard?
             (lambda () (normalize-messages (list (list 'user 42))))))
