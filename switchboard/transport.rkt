#lang racket/base

;; The HTTP boundary. All provider traffic flows through one injected
;; procedure, current-post-json, so tests run without network and local
;; gateways can be swapped in one place.

(require json
         net/http-easy
         "error.rkt")

(provide current-post-json
         default-post-json
         bearer-headers)

;; (current-post-json) : (-> string? (hash/c symbol? string?) jsexpr? jsexpr?)
;; url, headers, json payload -> parsed json response.
(define (default-post-json url headers payload)
  (define response (post url #:headers headers #:json payload))
  (define status (response-status-code response))
  (define body
    (with-handlers ([exn:fail? (lambda (_) "")])
      (define b (response-body response))
      (if (bytes? b) (bytes->string/utf-8 b) (format "~a" b))))
  (if (and (>= status 200) (< status 300))
      (with-handlers ([exn:fail?
                       (lambda (_)
                         (raise-switchboard-status status
                                                   (format "non-JSON response body: ~a" body)))])
        (string->jsexpr body))
      (raise-switchboard-status status body)))

(define current-post-json
  (make-parameter default-post-json))

;; headers is an immutable hash of symbol -> string.
(define (bearer-headers key [extra (hash)])
  (define base
    (if key
        (hasheq 'authorization (string-append "Bearer " key))
        (hasheq)))
  (for/fold ([h base]) ([(k v) (in-hash extra)])
    (hash-set h k v)))
