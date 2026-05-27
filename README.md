# PC 文件智能整理工具

把游戏搬到 SSD/E 盘、把 AI 资料归集到 AI 盘，游戏存档跟着走，原位建目录联接让启动器无感知。

---

## 快速开始

### 1. 把整个 `PCOrganizer` 文件夹复制到目标电脑（任意位置均可）

### 2. 编辑 `config.psd1`，至少确认以下三项：

| 配置项 | 说明 | 示例 |
|---|---|---|
| `GameTargets` | 游戏迁移目标盘（优先选剩余空间最大的） | `@('D:\Games','E:\Games')` |
| `AIRoot` | AI 资料归集根目录 | `'E:\AI'` |
| `AIDriveLetter` | 虚拟盘盘符（映射 AIRoot） | `'F'` |

### 3. 右键 `Organize-PC.ps1` → 「以管理员身份运行 PowerShell」

或在管理员 PowerShell 里执行：

```powershell
# 仅预览（推荐第一次先这样跑）
powershell -ExecutionPolicy Bypass -File ".\Organize-PC.ps1"

# 实际执行
powershell -ExecutionPolicy Bypass -File ".\Organize-PC.ps1" -Apply
```

---

## 菜单说明

| 选项 | 功能 |
|---|---|
| 1 | 扫描磁盘 + 识别游戏 / AI 资料，生成 `logs\inventory_*.json` |
| 2 | 生成整理方案报告 `logs\plan_*.json`，不移动任何文件 |
| 3 | 执行游戏迁移（含存档跟随） |
| 4 | 初始化 AI 盘（建子目录 + subst 虚拟盘 + 开机启动项）并归集 AI 资料 |
| 5 | 升级 AI 盘为真实 NTFS 分区（高危，会修改分区表） |
| 6 | 回滚上一次操作 |
| 7 | 查看所有操作日志 |

---

## AI 盘两阶段方案

### 阶段一（立即可用，无需空余分区）

运行菜单 **4** 后：
- 在 `E:\AI\` 下自动建 `models / datasets / docs / misc` 子目录
- 用 `subst F: E:\AI` 把它映射成虚拟盘 `F:`
- 在开机启动项写入 `Mount-AIDrive.cmd`，重启后自动恢复虚拟盘

对 Ollama / ComfyUI / LM Studio 等 AI 程序来说，`F:\models\xxx` 和真盘没区别。

### 阶段二（等 E 盘游戏迁走后腾出空间）

运行菜单 **5**，脚本会：
1. 检测 E 盘可压缩空间是否足够
2. 三次确认后压缩 E 盘分区
3. 用释放的未分配空间新建 NTFS 分区并格式化为 `F:`
4. 把 `E:\AI\` 内容迁移到新分区根目录
5. 删除旧目录和 `subst` 开机项

> 阶段二操作前**请先把重要数据备份到外接存储**。

---

## 游戏存档处理

脚本会在以下位置搜索与游戏名匹配的存档目录：

- `%USERPROFILE%\Documents\My Games\<游戏名>`
- `%USERPROFILE%\Saved Games\<游戏名>`
- `%LOCALAPPDATA%\<游戏名>`
- `%APPDATA%\<游戏名>`

命中后存档会一并搬到 `<目标盘>\<游戏名>\__saves__\`，原位建 Junction，Steam / 游戏本体均无感。

---

## 目录联接（Junction）说明

脚本把目录搬走后，在**原路径**建一个 NTFS 目录联接（Junction）指向新位置。

- Steam、Epic 等启动器看到的路径没变，无需修改库配置
- 存档路径也不变，游戏内直接读写
- Junction 要求源盘和目标盘均为 NTFS（FAT32 不支持，会提示跳过）

---

## 回滚

任何操作完成后都会在 `logs\` 下生成 `op_*.json` 日志。  
选菜单 **6** 可一键反向：删除 Junction → robocopy 复制回原位 → 删除新位置文件。

---

## 文件结构

```
PCOrganizer\
├── Organize-PC.ps1          主入口脚本
├── config.psd1              用户配置
├── README.md                本文件
├── modules\
│   ├── DiskScan.psm1        磁盘扫描
│   ├── DetectGames.psm1     游戏识别
│   ├── DetectAI.psm1        AI 资料识别
│   ├── DetectSaves.psm1     游戏存档定位
│   ├── Move-WithJunction.psm1  robocopy 迁移 + Junction
│   ├── Setup-AIDrive.psm1   AI 盘初始化与升级
│   └── Rollback.psm1        回滚
└── logs\                    自动生成的日志目录
    ├── inventory_*.json
    ├── plan_*.json
    └── op_*.json
```

---

## 注意事项

- 必须以**管理员身份**运行（建 Junction 需要管理员权限）
- 建议先跑菜单 **1 → 2** 审核方案，确认无误再执行 **3 / 4**
- 大批量复制时建议暂时关闭杀毒软件的实时保护（避免误拦截 / 拖慢速度）
- 中途断电/强制关机可能导致数据不完整，如有意外请用 **6 回滚** 后再次尝试
- `WindowsApps` 目录（Xbox Game Pass 游戏）受系统保护，脚本默认跳过

---

## 需求 / 反馈

欢迎提 Issue 或 PR！
