# Codex Limit Bar

A native macOS menu-bar app that reads the active Codex CLI login, shows its 5-hour and weekly limits plus reset-credit expiries, remembers up to 100 previously seen accounts, recommends the next usable account, and can launch automatically at login.

## Run from source

```sh
swift run
```

## Build the app

```sh
swift build -c release
mkdir -p "Codex Limit Bar.app/Contents/MacOS" "Codex Limit Bar.app/Contents/Resources"
cp .build/release/CodexLimitBar "Codex Limit Bar.app/Contents/MacOS/"
cp Packaging/Info.plist "Codex Limit Bar.app/Contents/"
cp Packaging/Assets/AppIcon.icns "Codex Limit Bar.app/Contents/Resources/"
```

The app reads `CODEX_HOME/auth.json` when `CODEX_HOME` is set, otherwise `~/.config/codex/auth.json` or `~/.codex/auth.json`. It stores usage snapshots—not credentials—in `~/Library/Application Support/CodexLimitBar/accounts.json`.

To populate multiple accounts, switch the Codex CLI login and click refresh once for each account.
