#lang racket/base

(require rackunit
         switchboard)

(test-case "HTTP status maps to the matching subtype"
  (check-exn exn:fail:switchboard:auth?
             (lambda () (raise-switchboard-status 401 "bad key")))
  (check-exn exn:fail:switchboard:auth?
             (lambda () (raise-switchboard-status 403 "forbidden")))
  (check-exn exn:fail:switchboard:rate-limit?
             (lambda () (raise-switchboard-status 429 "slow down")))
  (check-exn exn:fail:switchboard:not-found?
             (lambda () (raise-switchboard-status 404 "no such model")))
  (check-exn exn:fail:switchboard:api?
             (lambda () (raise-switchboard-status 500 "boom"))))

(test-case "a 400 blaming the context window is its own subtype"
  (check-exn exn:fail:switchboard:context-window?
             (lambda () (raise-switchboard-status 400 "context length exceeded")))
  (check-exn exn:fail:switchboard:api?
             (lambda () (raise-switchboard-status 400 "invalid model name"))))

(test-case "api exceptions carry status and body"
  (define e
    (with-handlers ([exn:fail:switchboard:api? (lambda (e) e)])
      (raise-switchboard-status 429 "rate limited")
      #f))
  (check-equal? (exn:fail:switchboard:api-status e) 429)
  (check-equal? (exn:fail:switchboard:api-body e) "rate limited"))

(test-case "plain switchboard errors are not api errors"
  (define e
    (with-handlers ([exn:fail:switchboard? (lambda (e) e)])
      (raise-switchboard "bad configuration")))
  (check-true (exn:fail:switchboard? e))
  (check-false (exn:fail:switchboard:api? e)))
