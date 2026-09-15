# AGENTS.md

## プロジェクト概要

このリポジトリは、Windows Update の再起動要求と更新・再起動予定を監視し、ntfy へ通知する PowerShell ツールです。監視専用とし、更新の開始、PC の再起動、Windows Update 設定の変更は行わないでください。

## 対応環境

- Windows PowerShell 5.1 と PowerShell 7 の両方を考慮する。
- Windows 固有の機能（レジストリ、COM、タスクスケジューラ）を使用するため、実動作の確認は Windows 上で行う。
- 通常の監視処理に管理者権限を要求しない。管理者権限が必要なのは、原則としてタスクの登録・解除だけとする。

## 実装方針

- `Set-StrictMode`、`$ErrorActionPreference`、既存のエラー処理方針を維持する。
- 表示言語に依存する Windows UI の文字列解析を追加しない。構造化されたレジストリ値、COM API、タスク情報を優先する。
- 一つの情報源の取得失敗で、ほかの状態確認まで停止させない。
- 通知失敗と Windows Update の確認失敗を区別する。
- トークン、トピック、認証ヘッダーなどの秘密情報をログや状態ファイルへ書き込まない。
- `NTFY_SERVER_URL`、`NTFY_TOPIC`、`NTFY_TOKEN` 環境変数が設定ファイルより優先される仕様を維持する。
- Windows PowerShell 5.1 との互換性を壊す構文や、追加モジュールへの不要な依存を避ける。
- ユーザー向けメッセージとドキュメントは、既存に合わせて簡潔な日本語で記述する。

## ファイルの扱い

- `config.sample.json` は安全な例示値だけを含め、設定項目を変更した場合は更新する。
- `config.json` はローカル設定であり、コミットしない。
- `data/` 以下の状態、ログ、ローテーション済みログは実行時生成物であり、コミットしない。
- 既存ユーザーの `config.json`、状態、ログを削除・上書きしない。
- 動作や導入手順を変更した場合は `README.md` も更新する。

## 検証

変更内容に応じて、Windows 上で次を実行してください。

```powershell
# 構文確認（対象スクリプトごと）
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\Check-WindowsUpdateSchedule.ps1),
    [ref]$null,
    [ref]$errors
)
$errors

# 通知を送らない監視確認
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Check-WindowsUpdateSchedule.ps1 -NoNotify

# 明示的に許可された場合だけ実通知を確認
.\Send-TestNotification.ps1
```

- `Send-TestNotification.ps1` は外部へ通知するため、ユーザーの明示的な意図なしに実行しない。
- `Install-Task.ps1` と `Uninstall-Task.ps1` はシステム状態を変更するため、検証目的で勝手に実行しない。
- Windows 以外で検証する場合は、構文・静的確認までとし、Windows 固有機能を実行できたとは報告しない。

## 完了条件

- PowerShell 5.1 互換性と既存の安全性が保たれている。
- 秘密情報および実行時生成物が追跡対象になっていない。
- 振る舞いの変更が README とサンプル設定に反映されている。
- 実行した検証と、環境上実行できなかった検証を明確に報告する。
