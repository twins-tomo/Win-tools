# Chrome Portable アップデーター (chrome-portable-updater)

[PortableApps.com 版 Google Chrome Portable](https://portableapps.com/apps/internet/google_chrome_portable) を、**ユーザーデータを引き継いだまま**最新版に自動アップデートする PowerShell スクリプトです。

## なぜデータが引き継げるのか

PortableApps 版 Chrome Portable は、プログラム本体とユーザーデータがフォルダで分かれています。

```
GoogleChromePortable\
├─ GoogleChromePortable.exe   ← ランチャー
├─ App\Chrome-bin\            ← プログラム本体 (chrome.exe など) ← ここだけ入れ替える
└─ Data\                        ← ユーザーデータ (ここには一切触らない)
   ├─ profile\                  ブックマーク・履歴・パスワード・拡張機能・設定
   └─ settings\
```

このスクリプトは `App\Chrome-bin` だけを新しい本体に入れ替えるので、`Data` フォルダの中身 (プロファイル) はそのまま新しい Chrome が読み込みます。

## 動作の流れ

1. 現在のバージョンを確認
2. Google の Version History API で最新の安定版を確認し、新しくなければ何もせず終了
3. Google 公式のスタンドアロンインストーラ (`ChromeStandaloneSetup64.exe` など、常時最新版を配布する URL) をダウンロードし、**電子署名が Google のものであることを検証**
4. インストーラを**実行せず**、7-Zip で多段展開して Chrome 本体を取り出す
5. 旧 `App\Chrome-bin` を `Backup` フォルダへ退避してから新版に入れ替え (コピー後のバージョン確認に失敗したら自動で旧版に戻す)
6. 入れ替え履歴を `Backup\update-history.txt` に記録

管理者権限は不要です。インストール作業自体を行わないため、レジストリや通常版 Chrome には影響しません。

### インストーラの多段展開について

現在の Google 公式インストーラは入れ子構造になっており、本体は一番奥の `chrome.7z` の中に入っています (この構造は 2026 年 11 月時点のインストーラで実地に展開して確認しました)。

```
ChromeStandaloneSetup64.exe
└─ updater.7z
   └─ <バージョン>_chrome_installer.exe
      └─ chrome.7z
         └─ Chrome-bin\ (chrome.exe + <バージョン> フォルダ)
```

将来 Google がこの構造を変えた場合は展開に失敗して中断します。その場合も、入れ替え前の段階で止まるため、既存の Chrome が壊れることはありません。

> なお、企業向け MSI (`googlechromestandaloneenterprise64.msi`) は中身のファイルを持たない自己展開ラッパー形式のため、この用途には使えません。そのため EXE 版を使っています。

## インストールされていない場合

このスクリプトは**アップデート専用**です。Google Chrome Portable が見つからない場合は、インストールは行わず、次の案内を表示して終了します。

- PortableApps.com から手動でインストールすること: https://portableapps.com/apps/internet/google_chrome_portable
- インストール後、インストール先フォルダにスクリプトを置くか `-PortableDir` で指定して再実行すること

探した場所 (スクリプトのあるフォルダ、その親フォルダ、その直下の `GoogleChromePortable` フォルダ) や、指定されたフォルダに対象がなかった旨もあわせて表示します。

## 使い方

### 方法 1: ダブルクリック (おすすめ)

`Update-ChromePortable.ps1` と `Update-ChromePortable.bat` の 2 ファイルを **GoogleChromePortable フォルダの中** (GoogleChromePortable.exe と同じ場所) にコピーし、`Update-ChromePortable.bat` をダブルクリックします。

### 方法 2: PowerShell から

```powershell
# フォルダを指定して実行
.\Update-ChromePortable.ps1 -PortableDir "D:\PortableApps\GoogleChromePortable"

# 起動中の Chrome を自動で閉じて、更新後に起動し直す
.\Update-ChromePortable.ps1 -PortableDir "D:\PortableApps\GoogleChromePortable" -CloseChrome -Launch
```

### 方法 3: タスクスケジューラで定期実行

週に 1 回などの自動実行もできます (Chrome を閉じている時間帯にどうぞ)。

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"D:\PortableApps\GoogleChromePortable\Update-ChromePortable.ps1`" -CloseChrome"
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 6:00am
Register-ScheduledTask -TaskName "Update Chrome Portable" -Action $action -Trigger $trigger
```

## オプション

| オプション | 説明 |
|---|---|
| `-PortableDir <path>` | GoogleChromePortable フォルダを指定 (省略時はスクリプトの場所から自動検出) |
| `-Architecture x64\|x86\|ARM64` | 本体のアーキテクチャ (既定: x64)。既存の Chrome に合わせてください |
| `-Force` | バージョンが同じでも入れ替えを実行 |
| `-CloseChrome` | 起動中の対象 Chrome を自動で閉じる (指定しない場合は確認を求め、中断も選べます) |
| `-BackupProfile` | `Data\profile` を ZIP にして `Backup` へ保存 (プロファイルが大きいと時間がかかります) |
| `-BackupKeep <n>` | 旧本体バックアップの保持世代数 (既定: 1) |
| `-KeepWorkFiles` | ダウンロード・展開した作業ファイルを残す (デバッグ用) |
| `-Launch` | 更新後に Chrome Portable を起動 |

## 元に戻す (ロールバック)

`GoogleChromePortable\Backup\Chrome-bin_<旧バージョン>_<日時>` が旧本体です。

1. Chrome を閉じる
2. `App\Chrome-bin` を削除する
3. バックアップフォルダの名前を `Chrome-bin` に戻して `App` フォルダへ移動する

## 要件と注意

- Windows 10 / 11、Windows PowerShell 5.1 以降 (標準搭載)、インターネット接続
- 作業用に一時フォルダ (%TEMP%) へ **約 2 GB の空き容量**が必要です (インストーラ約 170 MB + 多段展開で合計約 1.5 GB を一時的に使います)
- 7-Zip は、PC にインストール済みのものがあればそれを使います。ない場合は、公式サイトから単体版コンソール (7-Zip Extra の `7za.exe`) を作業フォルダへ自動ダウンロードして使うので、事前のインストールは不要です
- 対象は PortableApps.com 版の構成 (`App\Chrome-bin` + `Data\profile`) のみです。Chrome++ を使うタイプなどの別形式のポータブル版には対応していません
- バージョンチェックに使う Version History API は段階的公開中のバージョンを先に返すことがあります。その場合はインストーラに含まれる版 (実際に配布されている最新版) で判定し直すので、古い版に巻き戻ることはありません
- 更新中は対象フォルダの Chrome を閉じてください (デフォルトでは確認が出ます)

## ライセンス

MIT License (リポジトリ直下の LICENSE を参照)
