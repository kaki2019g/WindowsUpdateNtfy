# Windows Update ntfy 監視

Windows Update の再起動要求や取得可能な再起動・更新予定を、1時間ごととPC起動時に確認して ntfy へ日本語で通知します。監視専用で、更新開始、再起動、Windows Update 設定変更は行いません。

## ntfy の準備

1. スマートフォンで App Store または Google Play を開き、公式の **ntfy** アプリをインストールします。
2. 推測されにくい、十分に長いランダムなトピック名を自分で決め、アプリで購読します。
3. `config.sample.json` を `config.json` という名前でコピーし、同じトピック名を `Topic` に設定します。

`ntfy.sh` の公開トピックは、トピック名を知る人が読み書きできる可能性があります。ユーザー名、更新名、社内情報などの機密情報を載せないでください。必要なら認証を設定した自前の ntfy サーバーを `ServerUrl` に指定し、トークンを `Token` または環境変数 `NTFY_TOKEN` で設定します。設定ファイルより `NTFY_SERVER_URL`、`NTFY_TOPIC`、`NTFY_TOKEN` 環境変数が優先されます。

## 設定とテスト

Windows PowerShell 5.1 または PowerShell 7 で、作業フォルダへ移動して実行します。

```powershell
Copy-Item .\config.sample.json .\config.json
notepad .\config.json
.\Send-TestNotification.ps1
```

実行ポリシーにより手動実行できない場合も、恒久変更はせず、そのプロセスだけ次のように実行できます。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Send-TestNotification.ps1
```

監視結果だけを安全に確認し、通知を送らないテスト:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Check-WindowsUpdateSchedule.ps1 -NoNotify
```

## インストール

PC起動時に SYSTEM として実行するタスクを登録するため、**管理者として開いた Windows PowerShell** で次を実行します。監視本体は通常動作中に昇格処理を行いません。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Task.ps1
```

タスクは1時間ごととPC起動時に実行され、実行を逃した場合は次に可能になった時点で開始します。多重起動を無視し、ウィンドウを表示せず、実行ポリシーを恒久変更しません。

## アンインストール

管理者として開いた Windows PowerShell で実行します。設定、ログ、状態ファイルは削除しません。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-Task.ps1
```

## 判定方法と制約

再起動要求は Windows Update の `RebootRequired`、Component Based Servicing の `RebootPending`、保留中ファイル操作を確認します。予定日時は Windows Update UX の構造化レジストリ値と UpdateOrchestrator のタスク情報を試します。更新件数は Windows Update Agent COM API のローカル情報から取得します。表示言語に依存する画面文字列は解析しません。

Windows のバージョン、更新段階、ポリシー、アクセス権によって予定日時を正確に取得できない場合があります。各情報源の失敗は他の判定を止めません。日時が取得できなくても再起動要求が検出されれば通知します。アクティブ時間外の自動再起動は、UpdateOrchestrator の将来の実行時刻が読めた場合に予定として扱います。

状態または予定日時が変わった場合だけ通知し、同じ予定について24時間前と1時間前にも各1回通知します。1時間間隔のため、PC停止中などは正確な境界時刻に通知できません。

## 保存場所

- ログ: `data\logs\monitor.log`（既定で1 MiBごと、5世代）
- 状態: `data\state.json`
- 設定: `config.json`

HTTP送信失敗はログへ記録しますが、Windows Update の確認自体は失敗扱いにしません。ログや状態ファイルに ntfy トークンは書きません。
