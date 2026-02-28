# confirmo-remote

接收 Codex hook 事件并写入本机 `~/.confirmo/codex-status`，用于让另一台机器上的 Confirmo 显示状态。
本文档里的项目脚本路径都相对于仓库根目录（`./bin/...`、`./src/...`）。

## 1. 启动接收端（在运行 Confirmo 的机器上）

```bash
git clone <your-repo-url> confirmo-remote
cd confirmo-remote
npm install
npx confirmo-remote serve --token "replace-with-a-strong-token"
```

默认监听：`127.0.0.1:17890`  
默认接口：`POST /v1/codex/event`  
健康检查：`GET /healthz`

## 2. 用 ngrok 暴露到公网（可选）

```bash
ngrok http 17890
```

假设 ngrok 给你的地址是：
`https://abc123.ngrok-free.app`

则上报地址是：
`https://abc123.ngrok-free.app/v1/codex/event`

## 3. 在运行 Codex 的机器上配置 hook 远程目标

编辑 `~/.confirmo/hooks/codex-remote.json`：

```json
{
  "token": "replace-with-a-strong-token",
  "timeoutMs": 1800,
  "targets": [
    "https://abc123.ngrok-free.app/v1/codex/event",
    {
      "url": "https://another-target.ngrok-free.app/v1/codex/event",
      "token": "another-token"
    }
  ]
}
```

说明：
- `targets` 支持字符串和对象。
- 字符串目标默认使用顶层 `token`。
- 对象目标可单独指定 `token`。
- 现有本地写入不受影响，始终保留，所以这是「本地 + 多远程」fan-out。

也可以用自动脚本（推荐，GitHub Pages）：

```bash
bash <(curl -fsSL https://him188.github.io/confirmo-remote/bin/configure-codex-remote.sh) \
  https://h1-confirmo.ngrok.app \
  --token "replace-with-a-strong-token" \
  --replace-targets
```

如果不想用 `bash <(...)`，也可以先下载再执行：

```bash
curl -fsSL -o ./configure-codex-remote.sh \
  https://him188.github.io/confirmo-remote/bin/configure-codex-remote.sh
chmod +x ./configure-codex-remote.sh
./configure-codex-remote.sh https://h1-confirmo.ngrok.app --token "replace-with-a-strong-token"
```

脚本会自动把裸域名补全为 `/v1/codex/event`，并且会：
- 自动安装 `~/.confirmo/hooks/confirmo-codex-hook.js`（缺失时）
- 自动修复 `~/.codex/config.toml` 里的 `notify` 指向 Confirmo hook
- 写入 `~/.confirmo/hooks/codex-remote.json`

## 4. 环境变量覆盖（可选）

这些环境变量会覆盖/补充文件配置：
- `CONFIRMO_REMOTE_TOKEN`
- `CONFIRMO_REMOTE_URL`（单目标）
- `CONFIRMO_REMOTE_TARGETS`（逗号或换行分隔多目标）
- `CONFIRMO_REMOTE_TIMEOUT_MS`

## 5. 接收端参数

```bash
npx confirmo-remote serve \
  --listen 127.0.0.1:17890 \
  --path /v1/codex/event \
  --token "replace-with-a-strong-token" \
  --status-dir ~/.confirmo/codex-status \
  --retention-hours 24 \
  --max-body-bytes 262144
```
