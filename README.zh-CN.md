# mac-unlock

[English](README.md)

按需运行的原生 Mac 普通锁屏解锁工具，为本地自动化提供 JSON 回执。

仅在已登录且通过核验的本人控制台会话内运行。不含蓝牙、网络监听、常驻守护进程、定时任务或内置唤醒能力；不支持唤醒已进入系统睡眠的电脑、FileVault、首次登录或已注销会话。显示器准备是单独的、需明确授权的步骤，见下文。

## 构建与安装

需要 macOS 以及 Xcode Command Line Tools 提供的 Swift（`xcode-select --install`）。

```sh
git clone https://github.com/Juns-g/mac-unlock.git
cd mac-unlock
sh build.sh
sh test.sh
sh install.sh
```

程序安装至 `~/Applications/MacUnlock.app`，CLI 安装至 `~/.local/bin/mac-unlock`。请自行将该目录加入 PATH，或使用完整路径调用。若已存在同名 App 或命令，安装脚本会拒绝覆盖。构建与测试脚本支持可选的输出目录参数。

CLI 通过 LaunchServices 启动 App。若由 Agent 宿主直接调用原生二进制，系统权限可能归属于宿主而非 App。`--app /path/MacUnlock.app` 仅供**只读**构建验证。

## 本机首次设置

1. 在「系统设置 → 隐私与安全性」中，为 **MacUnlock.app** 授予所需的辅助功能访问及事件投递权限（macOS 27 位于「设备控制和数据访问」，旧版为「辅助功能」）。本工具仅检查权限，不主动触发授权弹窗。
2. 在本人会话已解锁状态下，双击已安装的 App，或亲自运行 `mac-unlock setup --local-user`，在本地遮蔽输入框中录入登录密码。

密码仅存入本工具专属、非同步的通用 Keychain 条目，访问严格限定于已安装的可执行文件。绝不接受密码参数、环境变量、管道、剪贴板或明文文件。Agent 严禁执行 setup 或无参数启动 App。

构建采用临时签名与标识 `com.example.MacUnlock`。重新构建会改变代码签名：须在系统设置中重新授权 App；若 Keychain 拒绝访问，须由本人重新录入。不继承其他安装的权限或凭据。请保持安装路径固定。

## 使用

```sh
mac-unlock status
mac-unlock preflight --clear-first
mac-unlock unlock --dry-run --clear-first
# 仅在用户明确授权本次机器操作与清空此密码框时执行：
mac-unlock unlock --authorize --clear-first
```

`status`、`preflight` 与 `--dry-run` 绝不读取凭据，亦不发送输入。`already_unlocked` 仅表示无需操作（no-op），不证明权限或凭据已就绪。无参数运行 CLI 仅输出帮助；`mac-unlock --help` 列出所有命令（包括经显式授权的重新锁屏）。

默认解锁要求密码框经核验为空；若 macOS 未暴露字符数则直接阻断。经显式授权的 `--clear-first` 会在单次提交前向已核验的密码框发送 Command-A/Delete。目标与凭据检查优先执行，凭据读取失败即刻中止且不清空。回执记录实际空框证据，不声称已独立证实清空。

退出码：`0` 结果已确认或无需操作；`2` 阻断；`3` 已尝试输入或完成状态未知；`64` 参数无效。失败或回执超时不得触发自动重试。

### 解锁前先准备闲置显示器

即使锁屏密码界面已隐藏，系统仍可能允许读取已聚焦、已启用的安全密码框。因此，预检 `ready` 是必要条件，却不能证明可见界面已准备好接收输入。不要用提交密码来唤醒显示器。

对于普通锁屏会话，用户明确授权解锁**及**显示器准备后，可用 macOS 系统命令 `caffeinate` 短时声明用户活动，不改变永久电源设置：

```sh
caffeinate -u mac-unlock preflight --clear-first
# 核对 JSON：会话已验证、仍锁定、权限及目标通过、结果为 ready。
# 另行确认正确的锁屏密码控件确实可见。
# 仅在明确授权解锁及清空该已核验字段后执行：
caffeinate -u mac-unlock unlock --authorize --clear-first
mac-unlock status
```

`caffeinate` 只准备显示器，不执行认证、不证明空框、不绕过守卫，也不将电脑从系统睡眠中恢复。上例的声明持续到被调用命令退出；macOS 在带 utility 时忽略 `-t`，因此额外加 `-t 45` 不会设置 45 秒截止。助手仍会执行自己的目标、会话、权限、凭据和单次输入检查。以 App 的 JSON 回执为准，不把启动命令的退出状态当作成功；`unlocked_confirmed` 后，新进程 `status` 再确认同一已验证会话为 unlocked，才是成功。`already_unlocked` 仍仅表示无需操作。

尝试失败后先停止，不自动重复清空或提交。只读系统日志中的 `View is hidden`、`userIsActiveCheck` 返回 `0`，或 `_wakeForIncomingMessage` 后出现 `don't start the Unlock`，是界面未就绪的线索，不证明密码错误。只有用户知情明确重新请求、前置问题已纠正并独立核验，再做新预检，才可进入一次新尝试；不能做前态不变的重试循环。排查时不输出或收集密码内容。

这套准备流程已在此前验收的原生实现上，针对闲置显示器导致的失败实际成功；未修改公开 App 或其安装身份，也不声称公开标识版已完成新的录密解锁测试。

## 安全与限制

- 必须核验本人控制台 UID/会话与锁屏状态。目标必须是同用户唯一的 `loginwindow` 进程及其精确 bundle 与可执行文件，且密码框必须安全、已启用并已聚焦。
- 权限与目标守卫通过后才读取独立凭据；Keychain 拒绝即刻终止，不弹窗提示，亦不清空输入框。
- 解锁前预先分配所有输入事件，定向投递到已核验的 PID，并在每对事件前复核同一字段与会话。焦点改变或部分输入立即终止且无重试。并发尝试不可交错。
- 成功必须以独立观察到会话转为已解锁为准；仅投递事件不构成确认。macOS 辅助功能与事件投递仍受系统竞态限制；本工具并非特权登录插件。
- 不更改系统安全设置、登录密码、FileVault 配置或全局权限。
- 工具前身曾在 macOS 27.2 完成过一次普通锁屏解锁；此公开标识版仅通过构建、合成与只读验证，未以新身份重新实测录密解锁。兼容性取决于系统能否暴露可核验目标及用户本机授权。

## 许可证与致谢

MIT 许可证；详见 [LICENSE](LICENSE)。独立实现，未复制上游源文件。Keychain 至 CGEvent 的解锁机制受 [ts1/BLEUnlock](https://github.com/ts1/BLEUnlock) 启发。
