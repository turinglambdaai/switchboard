#lang info

(define collection 'multi)
(define deps
  '(["base" #:version "9.0"]
    "http-easy-lib"))
(define build-deps '("rackunit-lib" "racket-doc" "scribble-lib"))
(define pkg-desc "One uniform chat, tool, and embedding API for every LLM provider")
(define version "0.1")
(define pkg-authors '(turinglambdaai))
(define license 'Apache-2.0)
