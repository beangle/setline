---
description: D 语言编码要求：克制抽象，少概念、少层级
globs: "**/*.d"
alwaysApply: false
---

# D 语言编码要求

## 核心原则

每个函数、类型、模块名都是一个**记忆点**。新增名字要有明确理由；能内联、能复用现有代码就不要再抽一层。

## 何时才值得单独成函数

- 两处及以上**真实调用**（例如启动与 CLI 共用 `mountDoc`）
- 规则/校验只应在一处定义，避免解析、CLI、测试各写一遍
- 逻辑足够长或分支足够多，拆开后主流程更易读

## 避免的做法

```d
// ❌ 一行逻辑包成函数，且只调用一次
string wwwDocEndpoint(string name) { return "/" ~ name; }

// ❌ 公开 API 再转发到 XxxImpl，中间无额外逻辑
static bool mountDoc(...) { return mountDocImpl(...); }

// ❌ 为每种 provider 再套工厂/接口/服务层，而现有 cast 分支已够用
```

```d
// ✅ 简单映射留在唯一需要语义的地方
string endpoint() const { return "/" ~ name; }

// ✅ 校验函数：parse 与 assert 共用同一规则
bool isValidDocName(string s) pure { ... }
```

## 抽象与类型

- 不引入「仅为好看」的中间类型、错误类层次、配置 DTO
- 校验失败：直接 `throw new Exception("...")`，信息写清楚即可
- 不为尚未出现的扩展点预留接口（YAGNI）
- 注释只解释非显而易见的业务或陷阱，不自述代码在做什么

## 命名与文件

- 名字说清**做什么**，避免 `Impl`、`Helper`、`Util` 堆叠
- 新模块/file 要有边界（如 `www`、`asset`）；不要把一次性的 5 行逻辑拆到新文件
- 与仓库现有风格一致：命名、import、`const`、日志方式跟随周边代码

## 改动习惯

- **最小 diff**：只改任务相关代码
- 删比加更重要：合并、内联后删掉不再使用的函数
- 测试覆盖行为，不为 trivial getter/一行转发单测
