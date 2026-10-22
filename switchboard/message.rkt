#lang racket/base

;; Conversation messages. Roles are symbols ('system 'user 'assistant
;; 'tool); the wire formats are produced only by wire.rkt. List-form input
;; ((list 'user "hi")) is accepted at the edge and normalized to structs,
;; so downstream code never re-validates shapes.

(require racket/list
         "error.rkt"
         "tool.rkt")

(provide (struct-out message)
         system-message
         user-message
         assistant-message
         tool-result-message
         normalize-messages)

;; content is a string, or #f for an assistant message that only carries
;; tool calls.
(struct message (role content tool-calls tool-call-id name) #:transparent)

(define (system-message content)
  (message 'system content '() #f #f))

(define (user-message content)
  (message 'user content '() #f #f))

(define (assistant-message content
                           #:tool-calls [tool-calls '()]
                           #:name [name #f])
  (message 'assistant content tool-calls #f name))

(define (tool-result-message content
                             #:tool-call-id tool-call-id
                             #:name [name #f])
  (message 'tool content '() tool-call-id name))

(define (checked-role role)
  (define sym
    (cond [(symbol? role) role]
          [(string? role) (string->symbol (string-downcase role))]
          [else (raise-switchboard
                 (format "switchboard: message role must be a symbol or string, got ~s" role))]))
  (case sym
    [(system user assistant tool) sym]
    [else (raise-switchboard
           (format "switchboard: unknown message role ~s (expected system, user, assistant, or tool)"
                   role))]))

(define (normalize-one-message m)
  (cond
    [(string? m) (user-message m)]
    [(message? m)
     (define role (checked-role (message-role m)))
     (when (and (eq? role 'assistant)
                (not (message-content m))
                (null? (message-tool-calls m)))
       (raise-switchboard
        "switchboard: an assistant message needs content or tool calls"))
     (when (and (eq? role 'tool) (not (message-tool-call-id m)))
       (raise-switchboard
        "switchboard: a tool result message needs #:tool-call-id"))
     (struct-copy message m [role role])]
    [(and (list? m) (= (length m) 2)
          (or (symbol? (car m)) (string? (car m)))
          (string? (cadr m)))
     (message (checked-role (car m)) (cadr m) '() #f #f)]
    [else
     (raise-switchboard
      (format "switchboard: bad message ~s (expected a string, a message, or (list role content))"
              m))]))

;; Accepts a string, one message, or a list mixing strings, messages, and
;; (list role content) forms; always returns a fresh (listof message?).
(define (normalize-messages messages)
  (cond
    [(or (string? messages) (message? messages))
     (list (normalize-one-message messages))]
    [(list? messages) (map normalize-one-message messages)]
    [else
     (raise-switchboard
      (format "switchboard: bad messages value ~s (expected a string, a message, or a list)"
              messages))]))
