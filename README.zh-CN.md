# Switchboard

**一次调用，接通所有模型——chat、工具调用与 embeddings 的统一 Racket API。**

[![CI](https://github.com/turlamai/switchboard/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/switchboard/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

**[English](README.md) · 中文**

Switchboard 是 Racket 程序的 LLM 接入层。每个模型都用 `"provider/model"` 字符串寻址，所有 provider 走同一套 chat / 工具调用 / embeddings 接口，所有失败都落到同一套结构化异常层级。OpenAI 兼容端点（OpenAI、Gemini、Mistral、DeepSeek、Ollama、以及自行注册的任意端点）共享同一条代码路径；Anthropic 有原生 Messages API 适配。

Switchboard 不是 agent 框架、提示词库或向量库。它只拥有你的代码与模型 API 之间的那一层边界，并且在那里不做任何隐藏动作：不重试、没有隐藏的默认 provider、没有隐式模型。

## 快速开始

```racket
(require switchboard)

(ask "openai/gpt-4o-mini" "What is 2 + 2?")
;; => "2 + 2 equals 4."
```

本地运行时无需密钥：

```racket
(ask "ollama/qwen3:1.7b" "Name three sorting algorithms.")
```

接入其他 OpenAI 兼容端点只需一条注册：

```racket
(add-provider!
 (provider 'groq "https://api.groq.com/openai/v1"
           '("GROQ_API_KEY") #t 'openai))
(ask "groq/llama-3.1-8b-instant" "Say hi.")
```

## 工具就是 Racket 函数

```racket
(define weather
  (make-tool "get_weather" "Current weather for a city"
             (list (parameter 'location "string" "City name"))
             (lambda (args)
               (format "Sunny, 22C in ~a" (hash-ref args 'location)))))

(response-content
 (chat-with-tools "openai/gpt-4o-mini"
                  (list (user-message "What's the weather in Paris?"))
                  (list weather)))
```

模型的调用以结构化 `tool-call` 值返回；`chat-with-tools` 负责执行并回灌结果，直到模型给出最终回答。工具失败——未知工具、缺参数、处理过程抛错——都会变成给模型看的 `"Error: ..."` 字符串，绝不会炸掉你的循环。

## Embeddings

```racket
(embed "openai/text-embedding-3-small" '("hello" "world"))
;; => '(flvector ... flvector ...)
```

## 可分派的错误

```
exn:fail:switchboard
└── exn:fail:switchboard:api          (status, body)
    ├── exn:fail:switchboard:auth             401, 403
    ├── exn:fail:switchboard:rate-limit       429
    ├── exn:fail:switchboard:not-found        404
    └── exn:fail:switchboard:context-window   400 归咎上下文窗口
```

重试与退避策略归你所有：Switchboard 抛结构化异常，不做任何隐藏重试。

## 设计要点

- **显式路由。** 模型字符串永远带 provider 前缀；裸模型名直接拒绝——拼写错误应当响亮地失败，而不是悄悄打到错误的供应商。
- **传输可注入。** 所有 HTTP 都经过一个参数 `current-post-json`。测试不碰网络；本地网关一处换装。
- **形态稳定。** 消息是符号 role 的结构体；wire 格式不泄漏进用户代码。`wire.rkt` 特意公开，供新增 provider 时复用。
- **只出结构化失败。** 每个 provider 错误都以 switchboard 异常子类越过边界。

## 开发

```sh
raco pkg install --auto --name switchboard .
raco test -p switchboard
raco setup --check-pkg-deps switchboard
```

CI 在 Linux、Windows、macOS 三平台 × Racket 9.0 / 9.3 上跑测试，并做依赖声明检查与参考手册构建。

## 许可证

[Apache-2.0](LICENSE)
