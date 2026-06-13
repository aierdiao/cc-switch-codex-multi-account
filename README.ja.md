# cc-switch-codex-multi-account

[简体中文](README.md) | [English](README.en.md) | 日本語

OpenAI または CC Switch 公式のツールではありません。コミュニティ向けの非公式ツールです。

![Windows](https://img.shields.io/badge/Windows-10%20%2F%2011-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)
![Codex CLI](https://img.shields.io/badge/Codex%20CLI-0.139.0%20tested-111111)

この Windows 用ヘルパーは、複数の ChatGPT/Codex アカウント用に分離された Codex の `auth.json` を生成し、それぞれを CC Switch の OpenAI Official Codex Provider に手動で貼り付けて使うためのものです。

## 用途

このツールは次の用途向けです。

```text
Codex CLI / VS Code Codex
→ CC Switch 経由で複数の ChatGPT アカウントを切り替える
```

CC Switch に内蔵されている Claude Provider 向けの Codex OAuth とは用途が異なります。

## 安全に関する説明

- スクリプトはローカルの Windows 環境だけで処理します。
- ユーザーデータをアップロードまたは収集しません。
- 認証ファイルはローカルの `.codex-account-N` フォルダーに保存されます。
- 管理者権限は必須ではありません。
- `codex logout` は実行しません。
- CC Switch の内蔵 OAuth 設定は変更しません。
- セキュリティが気になる場合は、実行前にコードを確認してください。

## 必要なもの

- Windows 10 または Windows 11
- Windows PowerShell 5.1 または PowerShell 7+
- Codex CLI
- CC Switch
- Google Chrome または Microsoft Edge

Codex CLI の確認：

```powershell
codex --version
```

## クイックスタート

1. GitHub Releases から ZIP をダウンロードします。
2. ZIP を展開します。
3. 次のファイルをダブルクリックします。

```text
run-setup.cmd
```

4. 追加したい Codex アカウント数を入力します。
5. 各アカウントについてブラウザーでログインします。
6. スクリプトが生成された `auth.json` をクリップボードにコピーします。
7. CC Switch の Codex Provider に貼り付けます。
8. PowerShell に戻って Enter を押すと、次のアカウントに進みます。

画像付きの詳しい手順は[簡体字中国語版](README.md#设置说明)を参照してください。

## ファイル構成

```text
setup-codex-accounts.ps1
run-setup.cmd
README.assets/
```

- `setup-codex-accounts.ps1`: メインスクリプト。
- `run-setup.cmd`: ダブルクリック用ランチャー。PowerShell 7 を優先し、なければ Windows PowerShell 5.1 を使います。

## アカウント用フォルダー

長期保存する認証元は、デフォルトの `.codex` には直接置きません。

```text
%USERPROFILE%\.codex
    CC Switch の live スロット

%USERPROFILE%\.codex-account-1
    Codex Account 1 の認証元

%USERPROFILE%\.codex-account-2
    Codex Account 2 の認証元
```

## 既存アカウントがある場合

有効なログインが既にある場合、次のように表示されます。

```text
A valid login already exists for Codex Account 1. [R]euse, [N]ew login, [S]kip, [Q]uit
```

- `R`: 既存ログインを再利用し、`auth.json` をクリップボードへコピーします。
- `N`: 再ログインします。古い `auth.json` はバックアップされ、新しいログインに失敗した場合は復元されます。
- `S`: このアカウントをスキップします。
- `Q`: 処理を終了します。

## よくあるエラー

### 429 Too Many Requests

デバイスコード要求がレート制限された場合は、15 から 30 分ほど待ってから再試行してください。

このエラーを解決するために `codex logout` を実行しないでください。

### Enter 待ちの画面

`auth.json` を CC Switch に貼り付けたあと Enter を押す画面には、スクリプト側のタイムアウトはありません。CC Switch の設定をゆっくり行ってから戻ってきても大丈夫です。

## AI エージェント向け実装メモ

このスクリプトは `codex login --device-auth` の人間向け出力を解析しません。

Codex app-server の stdio JSON-RPC を使い、デバイスコードは次の構造化フィールドから取得します。

```text
account/login/start
type = chatgptDeviceCode
result.userCode
result.verificationUrl
```

正規表現で CLI 出力を推測する実装に戻さないでください。

## セキュリティ上の注意

次の情報を公開しないでください。

- `auth.json`
- refresh token
- access token
- device code
- CC Switch のデータベースバックアップ

次のフォルダーを Git にコミットしないでください。

```text
.codex-account-*
.codex
.cc-switch
```
