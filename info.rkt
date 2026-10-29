#lang info

(define collection 'multi)
(define deps
  '(["base" #:version "9.0"]
    "http-easy-lib"
    "rackunit-lib"))
(define build-deps '("racket-doc" "scribble-lib"))
(define pkg-desc "One uniform chat, tool, and embedding API for every LLM provider")
(define version "0.1")
(define pkg-authors '(turlamai))
(define license 'Apache-2.0)
