#lang racket/base

;; Tools are ordinary Racket procedures the model may call. Execution
;; failures never escape run-tool-calls: they become "Error: ..." result
;; strings, which is the model's feedback channel. A crashing tool must not
;; crash an agent loop.

(require json
         racket/format
         racket/list
         racket/string
         "error.rkt")

(provide (struct-out parameter-spec)
         (struct-out tool)
         (struct-out tool-call)
         (struct-out tool-result)
         parameter
         make-tool
         make-tool-call
         tool-json-schema
         run-tool-calls)

(struct parameter-spec (name type description required? enumeration) #:transparent)

(struct tool (name description parameters procedure) #:transparent)

;; arguments is a hash with symbol keys; raw-arguments keeps the original
;; JSON text when the call arrived over the wire (#f when built locally).
(struct tool-call (id name arguments raw-arguments) #:transparent)

(struct tool-result (call-id name output) #:transparent)

(define (parameter name type description
                   #:required [required? #t]
                   #:enum [enumeration #f])
  (parameter-spec (checked-name 'parameter name)
                  (cond [(symbol? type) (symbol->string type)]
                        [(string? type) type]
                        [else (raise-argument-error 'parameter "(or/c symbol? string?)" type)])
                  (unless-string 'parameter description)
                  required?
                  enumeration))

(define (make-tool name description parameters procedure)
  (unless (procedure? procedure)
    (raise-argument-error 'make-tool "procedure?" procedure))
  (tool (checked-name 'make-tool name)
        (unless-string 'make-tool description)
        (for/list ([p (in-list parameters)])
          (if (parameter-spec? p) p (parameter (car p) (cadr p) (caddr p))))
        procedure))

(define (make-tool-call id name [arguments (hash)])
  (define-values (args raw)
    (cond
      [(hash? arguments) (values arguments #f)]
      [(string? arguments)
       (define parsed
         (with-handlers ([exn:fail? (lambda (_) #f)])
           (string->jsexpr arguments)))
       ;; Normalize to an equal-based hash: string->jsexpr yields hasheq,
       ;; and callers comparing against (hash ...) literals expect equal?.
       (if (hash? parsed)
           (values (for/hash ([(k v) (in-hash parsed)]) (values k v)) arguments)
           (values (hash) arguments))]
      [else (raise-argument-error 'make-tool-call "(or/c hash? string?)" arguments)]))
  (tool-call (format "~a" id) (checked-name 'make-tool-call name) args raw))

;; One tool as a JSON-schema fragment for the given wire format.
(define (tool-json-schema t kind)
  (define parameters
    (hash 'type "object"
          'properties
          (for/hash ([p (in-list (tool-parameters t))])
            (values (string->symbol (parameter-spec-name p))
                    (schema-property p)))
          'required
          (for/list ([p (in-list (tool-parameters t))]
                     #:when (parameter-spec-required? p))
            (parameter-spec-name p))))
  (case kind
    [(openai)
     (hash 'type "function"
           'function (hash 'name (tool-name t)
                           'description (tool-description t)
                           'parameters parameters))]
    [(anthropic)
     (hash 'name (tool-name t)
           'description (tool-description t)
           'input_schema parameters)]
    [else (raise-argument-error 'tool-json-schema "(or/c 'openai 'anthropic)" kind)]))

;; TOOLS is a list of tools or a name->tool hash. Returns one tool-result
;; per call, in order; every failure mode becomes an "Error: ..." string.
(define (run-tool-calls tools tool-calls)
  (define registry
    (if (hash? tools)
        tools
        (for/hash ([t (in-list tools)])
          (values (tool-name t) t))))
  (for/list ([call (in-list tool-calls)])
    (unless (tool-call? call)
      (raise-argument-error 'run-tool-calls "(listof tool-call?)" tool-calls))
    (tool-result (tool-call-id call) (tool-call-name call)
                 (run-one-tool registry call))))

(define (run-one-tool registry call)
  (define name (tool-call-name call))
  (define t (hash-ref registry name #f))
  (cond
    [(not t)
     (format "Error: no tool named ~s is registered" name)]
    [else
     (define arguments (tool-call-arguments call))
     (define missing
       (for/list ([p (in-list (tool-parameters t))]
                  #:when (and (parameter-spec-required? p)
                              (not (hash-has-key? arguments
                                                  (string->symbol (parameter-spec-name p))))))
         (parameter-spec-name p)))
     (cond
       [(pair? missing)
        (format "Error: tool ~a is missing required argument(s): ~a"
                name (string-join missing ", "))]
       [else
        (with-handlers ([exn:fail?
                         (lambda (e)
                           (format "Error: tool ~a failed: ~a" name (exn-message e)))])
          (define value ((tool-procedure t) arguments))
          (cond [(void? value) ""]
                [(string? value) value]
                [else (~a value)]))])]))

;; ---- helpers ----------------------------------------------------------

(define (checked-name who name)
  (cond [(symbol? name) (symbol->string name)]
        [(string? name) name]
        [else (raise-argument-error who "(or/c symbol? string?)" name)]))

(define (unless-string who value)
  (if (string? value)
      value
      (raise-argument-error who "string?" value)))

(define (schema-property p)
  (define h (hash 'type (parameter-spec-type p)
                  'description (parameter-spec-description p)))
  (if (parameter-spec-enumeration p)
      (hash-set h 'enum (parameter-spec-enumeration p))
      h))
