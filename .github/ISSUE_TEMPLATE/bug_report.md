---
name: Bug report / 问题反馈
about: 没播报、播报重复、武器/名字不对、报错或崩溃
title: "[Bug] "
labels: bug
---

<!--
请尽量填全。没有日志我们通常没法定位，谢谢配合！
Please fill in as much as you can - without the log we usually can't diagnose it.
-->

## 现象 / What happens

<!-- 例如：打死重甲后聊天框没有出现播报 / 武器显示不对 / 同一条播报重复出现 -->

## 复现步骤 / Steps to reproduce

1.
2.
3.

<!--
写清楚：哪只重甲、用什么武器打的、是房主还是客机、当时装没装别的击杀提示 mod。
Which heavy enemy, which weapon, were you host or client, and which other chat/kill-feed mods were installed.
-->

## 日志 / Log  ← 必填

<!--
文件位置：%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\HD2Runtime.log
只要本 mod 的行即可。PowerShell 一条命令复制到剪贴板：
  Get-Content "$env:LOCALAPPDATA\CowboyBingus\Helldivers2\Logs\HD2Runtime.log" | Select-String "heavy kill notice" | Set-Clipboard
Location: %LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\HD2Runtime.log  (search "heavy kill notice")
-->

```
（把日志粘贴到这里 / paste the log here）
```

## 其它 mod / Other mods

<!-- 是否装了别的改聊天 / 击杀提示 / 重甲相关的 mod -->

## 环境 / Environment

- Heavy Kill Notice 版本 / version:
- HD2Runtime 版本 / version:
- Bingus Shared Loader 版本 / version:
- 游戏版本、最近是否更新 / game version, updated recently?:
- 房主还是客机 / host or client:
