#lang racket/base

;; The response struct lives alone so the wire parsers (wire.rkt) and the
;; entry points (chat.rkt) can both produce it without a cycle.

(provide (struct-out response))

;; content is a string, or #f when the model only produced tool calls.
;; usage is a hash with input-tokens / output-tokens / total-tokens, or #f.
;; raw keeps the provider's JSON body for callers that need an extra field.
(struct response (content tool-calls stop-reason model usage raw)
  #:transparent)
