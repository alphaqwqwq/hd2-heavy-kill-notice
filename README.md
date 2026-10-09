# Heavy Kill Notice — 重甲击杀播报

潜兵击杀**重甲单位**时，向**全队聊天框**播报一行：**谁、用什么武器、击杀了哪只重甲**。
别人**不需要装这个 mod** 也能看到（走游戏自带的队伍聊天发送，就是按回车发消息的那个接口）。

> Requires **Bingus Shared Loader (API 1)** + **HD2Runtime**. Optional: CowboyBingus' Mod Options Menu.

---

## 效果

```
中文：alphaQAQ 用 EAT-17 击杀了 强袭虫
英文：alphaQAQ killed Charger with EAT-17
双语：alphaQAQ 用 EAT-17 击杀了 强袭虫 | alphaQAQ killed Charger with EAT-17
抓不到武器时（隐藏武器）：alphaQAQ 击杀了 强袭虫

紧凑（去动词）：alphaQAQ · 强袭虫 · EAT-17
里程碑（每 N 杀才播报）：alphaQAQ 干掉了 5 个重甲单位，才刚热身
```

- 覆盖 **32 种重甲**（强袭虫 / 孢子强袭虫 / 巨兽级强袭虫 / 穿刺虫 / 吐酸泰坦 / 霸王虫 /
  巨型者 / 炙焰者 / 抹煞者 / 战争纵步者 / 湮灭坦克 / 移动工厂 …），中英名都有。
- 对**全队任意玩家**生效，不只你自己。
- 武器用**真正造成击杀的那一击**（来自游戏的伤害队列），战备 / 支援武器也准确；
  抓不到就**隐藏武器**，不瞎猜。
- 每局按**击杀者**统计重甲击杀数（可按种类 / 本局总数 / 两者）。

## 安装 / 使用

1. 需要 **Bingus Shared Loader（API 1）** 与 **HD2Runtime**。
2. 用 **HD2 Arsenal** 导入 `dist/HeavyKillNotice-v1.6.0.zip` → 启用 → **Deploy**。
3. 进任务，打死一只重甲即可 —— **装好即用，不需要按任何键**。

## 选项（Escape > MODS > Heavy Kill Notice）

菜单文字可在游戏内**热切换语言**（English / 简体中文 / Bilingual）。

| 选项 | 默认 | 说明 |
|---|---|---|
| Enabled / 启用 | 开 | 总开关 |
| Chat broadcast / 播报方式 | 智能 | 智能（房主全部 / 客机只播报自己的击杀）/ 仅房主 / 每人 / 关闭 |
| Language / 语言 | 简体中文 | 中 / 英 / 双语（中英同一行） |
| Include weapon / 含武器 | 开 | 关掉就是「谁 击杀了 什么」 |
| Weapon source / 武器来源 | 仅精确 | 仅精确（抓不到就隐藏武器）/ 精确否则手持 / 仅手持 |
| Min gap / 最小间隔 | 1.0 s | 两次播报的最小间隔（防刷屏） |
| Display / 显示方式 | 完整 | 完整（每次击杀一行）/ **紧凑**（去动词，`A · 强袭虫 · EAT-17`）/ **里程碑**（每 N 杀才播报，风格化叙事） |
| Milestone step / 里程碑步长 | 5 | 里程碑模式下每 N 杀播报一次（5、10、15…）。称赞随累计升级：5=才刚热身 … 40=超标发挥 … 50=反重之神 |
| Test key (F9) / 测试键 | 关 | 排障用，按 F9 发一条测试消息 |
| Kill count / 击杀计数 | 关 | 按种类 / 本局总数 / 两者 |

## 已知限制

- **锁定单个游戏版本**（game.dll stamp `6AB3B43F`）：游戏更新后会**自动禁用**并在日志说明，等作者适配。
- 武器来自伤害队列的 dealer；若没抓到，「仅精确来源」会**隐藏武器**而不是猜。
- 「智能」模式避免重复：房主播报全部，客机只播报自己的击杀。
- 单条聊天消息游戏侧上限 **512 字节**。
- 纯内存、只读（只有一次调用游戏自带的聊天发送函数）；**不 hook、不改代码段、不改游戏文件**，重启即恢复。

## 报告 Bug（请务必附日志）

在 [Issues](https://github.com/alphaqwqwq/hd2-heavy-kill-notice/issues) 新建一条，并尽量附上：

1. **日志**：本 mod 写在 `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\HD2Runtime.log`（和其它 mod 共用同一个文件）。
   只要**本 mod 的行**即可，PowerShell 一条命令复制到剪贴板：

   ```powershell
   Get-Content "$env:LOCALAPPDATA\CowboyBingus\Helldivers2\Logs\HD2Runtime.log" | Select-String "heavy kill notice" | Set-Clipboard
   ```

   或整份日志（如果日志不长）：

   ```powershell
   Get-Content "$env:LOCALAPPDATA\CowboyBingus\Helldivers2\Logs\HD2Runtime.log" | Set-Clipboard
   ```

2. **复现步骤**：什么情况下没播报 / 播报错了（武器不对？名字不对？重复？），大概是第几只重甲。
3. **环境**：HD2Runtime 版本、Bingus Shared Loader 版本、游戏是否刚更新、是否装了其它改聊天 / 击杀提示的 mod。

**日志里最关键的行**（搜 `heavy kill notice`）：

```
heavy kill notice ready v1.6.0 (events=.. host=.. chat=.. names=..)   # 是否成功加载、是否房主、聊天是否可用、读到几个玩家名
heavy kill notice: killed #N: type=.. hx=.. heavy=.. peer=.. local_killer=.. enabled=..   # 每次击杀的判定链路
heavy kill notice: queued (.. weapon_src=damage|held, weapon=<hex>, killer_count=..)      # 武器来自哪条来源
heavy kill notice broadcast: <文本>            # 真正发出的内容
heavy kill notice send failed: <原因>          # 发送失败
heavy kill notice: damage scan resolved N dealer rows   # 伤害队列解析到几行
heavy kill notice: damage scan slow (.. ms, ..)         # 某次扫描耗时（性能）
```

> 判定口径：有 `killed` 但没有 `broadcast` → 是过滤 / 模式问题；连 `killed` 都没有 → 事件没触发。

## 目录结构

```
src/heavy_kill_notice.lua   mod 本体（Lua，含 --@CATALOG@ 注入点）
src/catalog_gen.lua         生成的名表（502 条：武器 + 敌人，32 重甲）
gen_catalog.py              名表生成器（BFV 分类 + DeathSourceNotice 中英名表合并）
build.py                    注入名表 → 语法检查 → 打包 → 容器校验（失败即停）
run_smoke_test.py           离线冒烟测试入口
check_labels.py             菜单文本长度校验（Mod Options Menu 上限）
test/smoke_test.lua         冒烟测试（假内存 + 假 hd2 + 假 ffi，真 LuaJIT）
dist/                       已构建的 ZIP
guid.txt                    固定 GUID（重复导入是「替换」）
```

## 从源码构建（开发）

```powershell
& "D:\py\python.exe" build.py            # 注入 + 语法 + 打包 + 校验
& "D:\py\python.exe" run_smoke_test.py   # 离线冒烟（33/33 断言）
```

> 打包依赖同工作区里的 `HD2ArchiveTool`（`make_mod.py` / `bingus_build.py`），脚本里也写了本机绝对路径，
> 所以**仓库里的构建脚本只在本机工作区可直接跑**；移植到别的机器需带上 `HD2ArchiveTool` 并改路径。

## 致谢 / Credits

- 击杀钩子：**HD2Runtime** 游戏事件（`entity_killed`）—— 与 **BFV Hit and Kill Feedback** 用的是同一个钩子。
- 玩家昵称（persona roster）与伤害队列武器归因：借鉴 **Death Source Notice / 死亡来源播报** 的方法。
- 聊天发送：游戏自带的**原生发送函数**，与 **notice** mod 相同。
- **HD2Runtime** by Skyeshade；**Bingus Shared Loader** 与 **Mod Options Menu** by CowboyBingus。

> AI disclosure: built with an AI assistant.

---

## English

When a Helldiver kills a **heavy enemy**, Heavy Kill Notice broadcasts one line to the **whole squad's
text chat**: **who killed which heavy, and with what**. Nobody else needs the mod — it sends through
the game's own team-chat call, the same one used when you press Enter.

- Requires **Bingus Shared Loader (API 1)** + **HD2Runtime**; optional Mod Options Menu.
- 32 heavy types; works for every player in the squad; weapon = the real killing blow (damage queue),
  so stratagems and support weapons are correct. If it is not captured, the weapon is hidden.
- Per-mission heavy-kill tally per killer.
- Memory-only and read-only, except one call into the game's own chat sender; no hooks, no code
  writes, no modified game files. Restarting the game removes it entirely.
- **Pinned to one game build** (`game.dll` stamp `6AB3B43F`); on any other build it disables itself
  and says so in the log.

**Bug reports:** open an issue and attach the mod's lines from
`%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\HD2Runtime.log` (search `heavy kill notice`):

```powershell
Get-Content "$env:LOCALAPPDATA\CowboyBingus\Helldivers2\Logs\HD2Runtime.log" | Select-String "heavy kill notice" | Set-Clipboard
```

plus the repro steps, your HD2Runtime / loader versions, and your other chat or kill-feed mods.
