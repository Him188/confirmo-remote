# confirmo-remote

让 Confirmo 支持远程 Codex 状态同步：
- `POST /v1/codex/event`：同步 turn-complete（原本 hook 事件）
- `POST /v1/codex/stream`：同步 Codex JSONL 流（用于 active/working 动画）

本文档里的项目脚本路径都相对于仓库根目录（`./bin/...`、`./src/...`）。

## 1. 启动接收端（Confirmo 机器）

```bash
git clone <your-repo-url> confirmo-remote
cd confirmo-remote
npm install
npx confirmo-remote serve --token "replace-with-a-strong-token"
```

默认监听：`127.0.0.1:17890`  
默认接口：
- `POST /v1/codex/event`
- `POST /v1/codex/stream`  
健康检查：`GET /healthz`

## 2. 用 ngrok 暴露到公网（可选）

```bash
ngrok http 17890
```

假设公网地址是 `https://h1-confirmo.ngrok.app`，那么上报地址会自动补全为：
- 事件：`https://h1-confirmo.ngrok.app/v1/codex/event`
- 流：`https://h1-confirmo.ngrok.app/v1/codex/stream`

## 3. 在 Codex 机器上一条命令配置（推荐）

```bash
bash <(curl -fsSL https://him188.github.io/confirmo-remote/bin/configure-codex-remote-all.sh) \
  https://h1-confirmo.ngrok.app \
  --token "replace-with-a-strong-token" \
  --replace-targets
```

这个一体化脚本会同时完成：
- 安装/修复 `~/.confirmo/hooks/confirmo-codex-hook.js`
- 修复 `~/.codex/config.toml` 的 `notify` 指向 hook
- 写入 `~/.confirmo/hooks/codex-remote.json`（支持多目标 fan-out，且保留本地写入）
- 安装并启动开机自启的 active bridge（launchd）

说明：
- `--replace-targets` 会替换所有远程目标；不加时默认 append（并去重）
- GitHub Pages 更新有缓存，push 后通常要等约 5 分钟再执行这条命令

## 4. 分步配置（可选）

仅配置事件上报：

```bash
bash <(curl -fsSL https://him188.github.io/confirmo-remote/bin/configure-codex-remote.sh) \
  https://h1-confirmo.ngrok.app \
  --token "replace-with-a-strong-token" \
  --replace-targets
```

仅配置 active bridge：

```bash
bash <(curl -fsSL https://him188.github.io/confirmo-remote/bin/configure-codex-active-bridge.sh) \
  --target https://h1-confirmo.ngrok.app \
  --token "replace-with-a-strong-token"
```

## 5. 多目标配置示例（本地 + 多远程）

本地写入始终存在。远程可配置多个目标：

```json
{
  "token": "replace-with-a-strong-token",
  "timeoutMs": 1800,
  "targets": [
    "https://h1-confirmo.ngrok.app/v1/codex/event",
    {
      "url": "https://another-target.ngrok.app/v1/codex/event",
      "token": "another-token"
    }
  ]
}
```

## 6. 环境变量覆盖（可选）

Hook 远程 fan-out：
- `CONFIRMO_REMOTE_TOKEN`
- `CONFIRMO_REMOTE_URL`
- `CONFIRMO_REMOTE_TARGETS`
- `CONFIRMO_REMOTE_TIMEOUT_MS`

Active bridge：
- `CONFIRMO_REMOTE_STREAM_URL`
- `CONFIRMO_REMOTE_TOKEN`
- `CONFIRMO_CODEX_SESSIONS_ROOT`
- `CONFIRMO_SOURCE`

## 7. 接收端参数

```bash
npx confirmo-remote serve \
  --listen 127.0.0.1:17890 \
  --path /v1/codex/event \
  --stream-path /v1/codex/stream \
  --token "replace-with-a-strong-token" \
  --status-dir ~/.confirmo/codex-status \
  --codex-sessions-root ~/.codex/sessions \
  --retention-hours 24 \
  --max-body-bytes 262144
```
