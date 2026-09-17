# Windows Update ON/OFF v1.5

这是一个面向维修烤机、装机验机和 72 小时稳定性测试场景的 Windows 10/11 本地工具。它用简单、直接、可恢复的方式暂时阻止 Windows Update，避免测试期间自动下载、安装或重启干扰稳定性结果。

## 使用方法

1. 解压完整目录，不要只单独复制 `.ps1` 文件。
2. 双击 `点我运行.bat`，接受管理员权限提示。
3. 点击 **Disable Windows Update** 前确认提示。首次禁用会先备份原始配置。
4. 测试完成后点击 **Enable / Restore Windows Update** 精确恢复。
5. **Refresh Status** 只刷新显示，不修改系统。

禁用后，Windows 设置中的 Windows Update 页面出现错误、无法检查更新或显示服务不可用，属于预期现象。这正是核心服务被硬禁用后的正常表现。

## v1.5 的禁用逻辑

- 停止并将 `wuauserv`、`BITS`、`DoSvc`、`UsoSvc` 的服务注册表 `Start` 硬设为 `4`（Disabled）。
- 同时调用 `sc.exe config`；无论 SCM 配置是否成功，仍采用 v1.2 验证过的直接注册表写入作为硬回退，并校验最终 `Start=4`。
- 将 `DoSvc\DelayedAutoStart` 设为 `0`，避免延迟自动启动语义残留。
- 写入以下策略值：

  - `DisableWindowsUpdateAccess=1`
  - `ExcludeWUDriversInQualityUpdate=1`
  - `NoAutoUpdate=1`
  - `NoAutoRebootWithLoggedOnUsers=1`
  - `NoAUShutdownOption=1`
  - `DetectionFrequencyEnabled=0`

策略即时回读异常只记为警告，不会把已经成功的服务硬禁用判成整体失败。四个核心服务的 `Start=4` 是主要成功标准；运行状态仍未停止时也会单独记录。

## 备份与恢复

第一次 Disable 在任何系统修改前，会在工具目录生成 `WU-ON_OFF-Tools-1.5.state.json`，记录：

- 每个核心服务原始 `Start`；
- `DelayedAutoStart` 原本是否存在及其原值；
- 服务当时是否正在运行；
- 六个策略值原本是否存在、注册表类型和原值；
- 计算机名和备份时间。

后续 Disable 不会覆盖这份原始备份。Restore 成功时逐项精确恢复；只有全部服务配置和策略都验证成功后才删除已消费的备份。失败时保留备份，便于再次恢复。

如果没有备份，GUI 会明确警告并要求确认，然后使用保守的安全恢复基线（不是所有 Windows 版本的“精确出厂值”）：

| 服务 | Start | DelayedAutoStart |
|---|---:|---:|
| wuauserv | 3（Manual） | 删除该值 |
| BITS | 3（Manual） | 删除该值 |
| DoSvc | 2（Automatic） | 1 |
| UsoSvc | 2（Automatic） | 1 |

无备份恢复还会只删除本工具管理的六个策略值，不删除整个 WindowsUpdate 策略树。

## 文件与日志

- `WU-ON_OFF-Tools-1.5.ps1`：GUI 入口。
- `src\WUTool.Core.psm1`：可测试的核心逻辑，导入模块不会产生系统副作用。
- `WU-ON_OFF-Tools-1.5.state.json`：首次 Disable 后生成的原始状态备份。
- `WU-ON_OFF-Tools-1.5.log`：运行日志。
- `tests\Test-WUTool.ps1`：仅做语法、纯函数、临时 HKCU 和临时文件测试；绝不调用 Disable/Restore。

## 安全说明

- 必须以管理员权限运行实际 Disable/Restore。
- 不要在 Windows 正在安装更新时强行禁用。
- 不要手工编辑或跨电脑复制状态备份；工具会校验计算机名与结构。
- 完成烤机或稳定性测试后应及时 Restore，并重新打开 Windows Update 检查状态。
