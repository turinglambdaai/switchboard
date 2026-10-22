#lang racket/base

;; Structured error hierarchy. Every provider failure crosses this boundary
;; as a switchboard exception subtype, so callers dispatch on one hierarchy
;; instead of parsing provider-specific error bodies.

(provide (struct-out exn:fail:switchboard)
         (struct-out exn:fail:switchboard:api)
         (struct-out exn:fail:switchboard:auth)
         (struct-out exn:fail:switchboard:rate-limit)
         (struct-out exn:fail:switchboard:not-found)
         (struct-out exn:fail:switchboard:context-window)
         raise-switchboard
         raise-switchboard-status)

(struct exn:fail:switchboard exn:fail () #:transparent)

;; A provider returned a non-2xx HTTP status. STATUS is the HTTP status
;; code, BODY the response body as a string.
(struct exn:fail:switchboard:api exn:fail:switchboard (status body) #:transparent)

(struct exn:fail:switchboard:auth exn:fail:switchboard:api () #:transparent)
(struct exn:fail:switchboard:rate-limit exn:fail:switchboard:api () #:transparent)
(struct exn:fail:switchboard:not-found exn:fail:switchboard:api () #:transparent)

;; HTTP 400 whose body blames the context window. Callers trim the
;; conversation and retry; every other 400 is a bug in the request.
(struct exn:fail:switchboard:context-window exn:fail:switchboard:api () #:transparent)

(define (raise-switchboard message-string)
  (raise (exn:fail:switchboard message-string (current-continuation-marks))))

(define (raise-switchboard-status status body)
  (define body-string (if (string? body) body (format "~s" body)))
  (define message
    (format "switchboard: provider returned HTTP ~a: ~a" status body-string))
  (define marks (current-continuation-marks))
  (cond
    [(member status '(401 403))
     (raise (exn:fail:switchboard:auth message marks status body-string))]
    [(equal? status 429)
     (raise (exn:fail:switchboard:rate-limit message marks status body-string))]
    [(equal? status 404)
     (raise (exn:fail:switchboard:not-found message marks status body-string))]
    [(and (equal? status 400)
          (regexp-match? #rx"(?i:context)" body-string))
     (raise (exn:fail:switchboard:context-window message marks status body-string))]
    [else
     (raise (exn:fail:switchboard:api message marks status body-string))]))
