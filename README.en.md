# cc-switch-codex-multi-account

[简体中文](README.md) | English | [日本語](README.ja.md)

Unofficial community tool. Not affiliated with OpenAI or CC Switch.

![Windows](https://img.shields.io/badge/Windows-10%20%2F%2011-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)
![Codex CLI](https://img.shields.io/badge/Codex%20CLI-0.139.0%20tested-111111)

This Windows helper creates isolated native Codex `auth.json` files for multiple ChatGPT/Codex accounts, then lets you paste each file into CC Switch as an OpenAI Official Codex provider.

## What This Is For

Use this when you want:

```text
Codex CLI / VS Code Codex
→ switch between different ChatGPT accounts through CC Switch
```

This is different from CC Switch's built-in Codex OAuth for Claude providers.

## Safety Notes

- The script works locally on your Windows machine.
- It does not upload or collect user data.
- Auth files are saved locally under `.codex-account-N`.
- It does not require administrator privileges.
- It does not run `codex logout`.
- It does not modify CC Switch's built-in OAuth center.
- If you have security concerns, review the code before running it.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or PowerShell 7+
- Codex CLI
- CC Switch
- Google Chrome or Microsoft Edge

Check Codex CLI:

```powershell
codex --version
```

## Quick Start

1. Download the ZIP from GitHub Releases.
2. Extract it.
3. Double-click:

```text
run-setup.cmd
```

4. Enter the number of Codex accounts you want to add.
5. Complete browser sign-in for each account.
6. The script copies the generated `auth.json` to your clipboard.
7. Paste it into a CC Switch Codex provider.
8. Return to PowerShell and press Enter to continue with the next account.

For a full walkthrough with screenshots, see the [Simplified Chinese guide](README.md#设置说明).

## Files

```text
setup-codex-accounts.ps1
run-setup.cmd
README.assets/
```

- `setup-codex-accounts.ps1`: main script.
- `run-setup.cmd`: double-click launcher. It prefers PowerShell 7 and falls back to Windows PowerShell 5.1.

## Account Directories

The script keeps long-term auth sources outside the default `.codex` folder:

```text
%USERPROFILE%\.codex
    CC Switch live slot

%USERPROFILE%\.codex-account-1
    Auth source for Codex Account 1

%USERPROFILE%\.codex-account-2
    Auth source for Codex Account 2
```

## Existing Accounts

If a valid account already exists, the script asks:

```text
A valid login already exists for Codex Account 1. [R]euse, [N]ew login, [S]kip, [Q]uit
```

- `R`: reuse the existing login and copy its `auth.json` to the clipboard.
- `N`: sign in again. The old `auth.json` is backed up and restored if the new login fails.
- `S`: skip this account.
- `Q`: stop processing.

## Common Errors

### 429 Too Many Requests

If device-code requests are rate-limited, wait 15 to 30 minutes and avoid repeated retries.

Do not run `codex logout` to fix this.

### Waiting At The Enter Prompt

The prompt after copying `auth.json` has no script timeout. You can take your time in CC Switch before pressing Enter.

## Implementation Notes For AI Agents

The script uses Codex app-server stdio JSON-RPC, not human-readable `codex login --device-auth` output.

The device code comes from:

```text
account/login/start
type = chatgptDeviceCode
result.userCode
result.verificationUrl
```

Do not change this back to regex-based CLI output parsing.

## Security Reminder

Never publish:

- `auth.json`
- refresh tokens
- access tokens
- device codes
- CC Switch database backups

Do not commit:

```text
.codex-account-*
.codex
.cc-switch
```
