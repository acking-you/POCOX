---
status: accepted
---

# OpenCode 每个主版本是原生客户端里的一个 `Wire` 实现，不是新的 engine

POCOX 按服务种类选定唯一的 `OpenCodeEngine`，控制器只走 `/opencode/v1`。OpenCode 2 换了原生 HTTP 和事件，但产品入口没有变。

决定：
- 原生线路的差异收在 `opencode/wire/`。每个主版本有一个 `Wire` 实现（`V1`、`V2`，都是无值类型），负责路由、请求体、响应投影和事件帧，以及版本范围、数据库命令和监听行。结果都是宿主、折叠和网关已经在读的 1.x 形状。
- `Launch::detect` 只解析一次 `--version`，由 `Dialect` 选出实现。调用经 `dispatch!` 的封闭 `match` 静态分发，不用 `dyn`，也不装箱 future。网关客户端是 `Http<Pocket>`，没有方言。
- 测试范围外的版本照常启动，宿主状态里给出提示；报不出数据库路径的版本无法托管。

不再做一个 engine：分发只看服务种类，版本差异只在 `opencode serve` 的线路上；新 engine 会复制网关、折叠和会话准入。

详见 [Native OpenCode › Versions](../opencode-native.md#versions)。
