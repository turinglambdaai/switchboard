#lang racket/base

(require rackunit
         switchboard)

(test-case "model strings split on the first slash only"
  (define-values (provider model)
    (parse-model "openai/gpt-4o-mini"))
  (check-equal? (provider-id provider) 'openai)
  (check-equal? model "gpt-4o-mini")

  (define-values (provider2 model2)
    (parse-model "fireworks-ai/accounts/me/models/deepseek-v3"))
  (check-equal? (provider-id provider2) 'fireworks-ai)
  (check-equal? model2 "accounts/me/models/deepseek-v3"))

(test-case "a bare model name is rejected, never silently defaulted"
  (check-exn exn:fail:switchboard?
             (lambda () (parse-model "gpt-4o-mini")))
  (check-exn exn:fail:switchboard?
             (lambda () (parse-model 'not-a-string))))

(test-case "#:provider overrides the string prefix"
  (define-values (provider model)
    (parse-model "my-fine-tune" #:provider 'openai))
  (check-equal? (provider-id provider) 'openai)
  (check-equal? model "my-fine-tune"))

(test-case "unknown providers fail with the known list"
  (check-exn exn:fail:switchboard?
             (lambda () (provider-ref 'nonexistent)))
  (check-exn
   exn:fail:switchboard?
   (lambda ()
     (with-handlers ([exn:fail:switchboard?
                      (lambda (e)
                        (unless (regexp-match? #rx"openai" (exn-message e))
                          (raise e))
                        (raise e))])
       (provider-ref 'nonexistent)))))

(test-case "explicit keys beat environment variables"
  (putenv "SWITCHBOARD_TEST_KEY" "from-env")
  (define p (provider 'test-provider "https://example.test/v1"
                      '("SWITCHBOARD_TEST_KEY") #t 'openai))
  (check-equal? (provider-api-key p "explicit") "explicit")
  (check-equal? (provider-api-key p #f) "from-env"))

(test-case "empty environment values are skipped"
  (putenv "SWITCHBOARD_TEST_KEY" "")
  (define p (provider 'test-provider "https://example.test/v1"
                      '("SWITCHBOARD_TEST_KEY") #t 'openai))
  (check-exn exn:fail:switchboard? (lambda () (provider-api-key p #f))))

(test-case "keyless providers resolve to #f"
  (define p (provider 'local "http://localhost:11434/v1" '() #f 'openai))
  (check-false (provider-api-key p #f)))

(test-case "scoped registries via parameterize"
  (check-false
   (member 'test-only (provider-names)))
  (parameterize ([current-providers
                  (hash-set (current-providers) 'test-only
                            (provider 'test-only "https://example.test/v1" '() #f 'openai))])
    (check-not-false (member 'test-only (provider-names))))
  (check-false (member 'test-only (provider-names))))

(test-case "add-provider! extends the global registry"
  (check-exn exn:fail:switchboard? (lambda () (provider-ref 'swb-test-provider)))
  (add-provider! (provider 'swb-test-provider "https://example.test/v1"
                           '() #f 'openai))
  (check-equal? (provider-base-url (provider-ref 'swb-test-provider))
                "https://example.test/v1"))
