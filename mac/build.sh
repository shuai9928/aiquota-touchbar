#!/bin/bash
# 编译 AIQuota.app，安装到 ~/Applications，设为登录时启动并运行。
#   ./build.sh              编译 + 安装 + 启动
#   ./build.sh --build-only 只编译到 build/
set -euo pipefail
cd "$(dirname "$0")"

NAME=AIQuota
LABEL=local.aiquota.menubar
APP="build/$NAME.app"
DEST="$HOME/Applications/$NAME.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 -lsqlite3 \
    -o "$APP/Contents/MacOS/$NAME" AIQuota.swift ProjectActions.swift Attention.swift Shelf.swift ShelfViews.swift ResetReminder.swift Relay.swift RelayViews.swift Prompts.swift PromptViews.swift Lights.swift Translate.swift ToolViews.swift Calm.swift Pet.swift Receipt.swift Watch.swift Roadmap.swift SessionSnapshot.swift AIPage.swift Piano.swift Setup.swift
cp Info.plist "$APP/Contents/Info.plist"
# app 里带一份 Chrome 歌词扩展和第三方授权：别的 Mac 上「接入…」时从这里放好扩展（打包见 package.sh）
mkdir -p "$APP/Contents/Resources"
if [ -d ../chrome ]; then rsync -a --delete ../chrome/ "$APP/Contents/Resources/ChromeExtension/"; fi
cp LICENSE.piano-upstream "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null

if [ "${1:-}" = "--build-only" ]; then
    echo "已编译：$APP"
    exit 0
fi

# 停掉正在运行的（包括 launchd 里的那份）
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# 只停菜单栏里那一个（命令行必须正好是 app 本身）；tb run、歌词桥、会话 hook 用的是同一个程序，不能一起杀掉
pkill -xf "$DEST/Contents/MacOS/$NAME" 2>/dev/null || true
sleep 1

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

# 登录时启动
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-g</string>
		<string>$DEST</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
EOF

# Chrome 歌词扩展：放到固定位置（不在「文稿」里，Chrome 读它不用额外授权），在 chrome://extensions 里「加载已解压的扩展程序」选这个目录
EXT="$HOME/Library/Application Support/AIQuota/ChromeExtension"
if [ -d ../chrome ]; then
    mkdir -p "$EXT"
    rsync -a --delete ../chrome/ "$EXT/"
fi

# tb 命令：在触控栏上点灯（只在没有别的 tb 时装，或者覆盖我们自己装的那个）；app 不在时 tb run 照样跑命令
TB="$HOME/.local/bin/tb"
if { [ ! -e "$TB" ] && [ ! -L "$TB" ]; } || grep -q "AIQuota" "$TB" 2>/dev/null; then
    {
        mkdir -p "$HOME/.local/bin" &&
        TMP_TB="$(mktemp "$HOME/.local/bin/.tb.XXXXXX")" &&
        cat > "$TMP_TB" <<TBEOF &&
#!/bin/sh
# AIQuota 的 tb：在触控栏上点灯
APP="$DEST/Contents/MacOS/$NAME"
if [ -x "\$APP" ]; then exec "\$APP" --tb "\$@"; fi
if [ "\$1" = "run" ]; then
    shift
    while [ \$# -gt 0 ]; do
        case "\$1" in
            --keep) shift ;;
            --name) shift; [ \$# -gt 0 ] && shift ;;
            --) shift; break ;;
            *) break ;;
        esac
    done
    exec "\$@"
fi
exit 0
TBEOF
        chmod +x "$TMP_TB" &&
        mv -f "$TMP_TB" "$TB"
    } || echo "没能装 tb 命令（不影响 app）"
fi

# 登记「服务」菜单里的「在触控栏上翻译」：只让装好的那一份提供服务（编译目录里那份不登记，免得系统去启动它）
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -u "$PWD/$APP" 2>/dev/null || true
"$LSR" -f "$DEST" 2>/dev/null || true
/System/Library/CoreServices/pbs -update 2>/dev/null || true

open -g "$DEST"
# open 是异步的：确认真的起来了（5 秒内没看到就再开一次）
for _ in 1 2 3 4 5; do pgrep -xf "$DEST/Contents/MacOS/$NAME" >/dev/null && break; sleep 1; done
if ! pgrep -xf "$DEST/Contents/MacOS/$NAME" >/dev/null; then
    open -g "$DEST"; sleep 2
    pgrep -xf "$DEST/Contents/MacOS/$NAME" >/dev/null || echo "警告：AIQuota 没有启动起来，请手动打开 $DEST"
fi
echo "已安装并启动：$DEST"
echo "开机启动：${PLIST}（在菜单栏面板里可以取消勾选）"
echo "Chrome 歌词扩展：$EXT"
