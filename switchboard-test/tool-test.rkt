#lang racket/base

(require racket/string
         rackunit
         switchboard)

(define get-weather
  (make-tool 'get_weather "Current weather for a city"
             (list (parameter 'location "string" "City name"))
             (lambda (args)
               (format "Sunny, 22C in ~a" (hash-ref args 'location)))))

(test-case "tools accept symbols or strings for names and params"
  (check-equal? (tool-name get-weather) "get_weather")
  (check-equal? (parameter-spec-name (car (tool-parameters get-weather)))
                "location"))

(test-case "make-tool rejects non-procedures"
  (check-exn exn:fail:contract?
             (lambda () (make-tool "t" "d" '() "not-a-proc"))))

(test-case "openai and anthropic schema shapes"
  (define openai-schema (tool-json-schema get-weather 'openai))
  (check-equal? (hash-ref openai-schema 'type) "function")
  (define fn (hash-ref openai-schema 'function))
  (check-equal? (hash-ref fn 'name) "get_weather")
  (check-equal? (hash-ref (hash-ref fn 'parameters) 'required) '("location"))

  (define anthropic-schema (tool-json-schema get-weather 'anthropic))
  (check-equal? (hash-ref anthropic-schema 'name) "get_weather")
  (check-true (hash-has-key? anthropic-schema 'input_schema)))

(test-case "enum constraints reach the schema"
  (define t
    (make-tool "sort" "Sort order"
               (list (parameter 'order 'string "Direction"
                                #:enum '("asc" "desc")))
               (lambda (args) "ok")))
  (define properties
    (hash-ref (hash-ref (tool-json-schema t 'openai) 'function) 'parameters))
  (check-equal? (hash-ref (hash-ref (hash-ref properties 'properties) 'order) 'enum)
                '("asc" "desc")))

(test-case "successful calls format non-string values"
  (define results
    (run-tool-calls (list get-weather)
                    (list (make-tool-call "call_1" "get_weather"
                                          (hash 'location "Paris")))))
  (check-equal? (length results) 1)
  (check-equal? (tool-result-call-id (car results)) "call_1")
  (check-equal? (tool-result-output (car results)) "Sunny, 22C in Paris"))

(test-case "unknown tools become error strings, not exceptions"
  (define results
    (run-tool-calls (list get-weather)
                    (list (make-tool-call "call_2" "get_time" (hash)))))
  (check-true (string-prefix? (tool-result-output (car results)) "Error:")))

(test-case "missing required arguments become error strings"
  (define results
    (run-tool-calls (list get-weather)
                    (list (make-tool-call "call_3" "get_weather" (hash)))))
  (check-true
   (and (string-contains? (tool-result-output (car results)) "missing required")
        (string-contains? (tool-result-output (car results)) "location"))))

(test-case "a crashing tool returns feedback for the model"
  (define bad
    (make-tool "bad" "Always fails"
               '()
               (lambda (args) (error "exploded"))))
  (define results
    (run-tool-calls (list bad) (list (make-tool-call "call_4" "bad" (hash)))))
  (check-true (string-contains? (tool-result-output (car results)) "failed")))

(test-case "wire calls parse their JSON arguments"
  (define call (make-tool-call "call_5" "get_weather" "{\"location\": \"Rome\"}"))
  (check-equal? (tool-call-arguments call) (hash 'location "Rome"))
  (check-equal? (tool-call-raw-arguments call) "{\"location\": \"Rome\"}")

  (define local (make-tool-call "call_6" "get_weather" (hash 'location "Oslo")))
  (check-false (tool-call-raw-arguments local)))

(test-case "a registry hash works too"
  (define results
    (run-tool-calls (hash "get_weather" get-weather)
                    (list (make-tool-call "c" "get_weather"
                                          (hash 'location "Tokyo")))))
  (check-equal? (tool-result-output (car results)) "Sunny, 22C in Tokyo"))
