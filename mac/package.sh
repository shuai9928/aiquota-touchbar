#!/bin/bash
# 打包成别的 Mac 打开就能装的 DMG：../dist/AIQuota-<日期>-<提交>.dmg
# 里面：AIQuota.app、「应用程序」快捷方式（拖进去就装好）、使用说明、卸载脚本、第三方授权。不带任何本机数据（配置、会话、指令、材料都不带）。
#   ./package.sh              先跑测试，再打包
#   ./package.sh --skip-tests 不跑测试（刚跑过的时候）
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" != "--skip-tests" ]; then ./test.sh; fi
./build.sh --build-only >/dev/null

DATE="$(date +%Y.%m.%d)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
if [ -n "$(git status --porcelain -- . ../chrome 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi
OUT="../dist"
WORK="$(mktemp -d -t aiquota-package)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/AIQuota"
mkdir -p "$STAGE" "$OUT"

cp -R build/AIQuota.app "$STAGE/"
PLIST="$STAGE/AIQuota.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DATE" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $DATE" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :AIQuotaCommit" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :AIQuotaCommit string $COMMIT" "$PLIST"
codesign --force --sign - "$STAGE/AIQuota.app" >/dev/null
codesign --verify --strict "$STAGE/AIQuota.app"
ln -s /Applications "$STAGE/应用程序"

mkdir -p "$STAGE/第三方授权"
cp LICENSE.piano-upstream "$STAGE/第三方授权/钢琴 pock-piano-widget（MIT）.txt"

cat > "$STAGE/使用说明.txt" <<EOF
AIQuota $DATE（$COMMIT）
在 Mac 菜单栏和触控栏上看 Claude / Codex 的 5 小时和每周额度、每个 AI 会话在干什么（等你、出错、做完），
工作流路线图、做完叫我、Claude↔Codex 接力、tb 命令行灯，还有放松用的小猫、番茄钟、呼吸、歌词和钢琴。

━━ 适用 ━━
· Apple 芯片的 Mac，macOS 13 或更新（划词翻译要 macOS 26）。Intel Mac 暂不支持。
· 触控栏部分：带触控栏的 13 英寸 MacBook Pro（M1 2020、M2 2022）。没有触控栏的 Mac 只用菜单栏，照样能看额度和会话。
· Claude 额度：要装 Claude 桌面 app 并登录（读它自己记的用量）。Codex 额度：要装 Codex 并登录（读 ~/.codex/auth.json，只读不改）。
  会话灯：Claude Code、Codex、ZCode 装了哪个接哪个。

━━ 安装（三步）━━
1. 把 AIQuota 拖到旁边的「应用程序」。（不要直接在这个窗口里打开：从安装盘里打开的不会接会话灯。）
2. 打开「应用程序」里的 AIQuota。
   第一次打开 macOS 会拦住（没有付费的苹果开发者签名）：
   · 打开「系统设置 → 隐私与安全性」，往下翻到「已阻止 AIQuota…」，点「仍要打开」，再输一次密码。
   · 或者在「终端」里运行：xattr -dr com.apple.quarantine /Applications/AIQuota.app
   （要是不小心在这个窗口里直接打开了，它会提示你，点「打开『应用程序』并退出」，再从「应用程序」里打开就行。）
3. 弹出「欢迎使用 AIQuota」窗口：勾上要接的（Claude Code / Codex / ZCode 会话灯、tb 命令、开机启动、Chrome 歌词扩展），点「设置」。
   改别的程序的配置前会先备份（同目录 *.bak-aiquota-时间），只动 AIQuota 自己的条目，别的不碰、不挪位置。
   以后想改（比如后来才装了 Codex——新装的 AI 它也会自己再问一次）：点菜单栏上的 AIQuota →「接入…」，勾上的接上，取消勾的去掉。

━━ 还要你自己做的 ━━
· 触控栏：系统设置 → 键盘 → 触控栏设置 → 打开「显示 Control Strip」。额度小图标在亮度、音量键左边，点它展开。
· Codex：第一次接上后要点一次信任——Codex 设置 → Hooks → 找到 6 条「AIQuota --hook codex」→ Trust。
· 已经开着的 AI 会话要新开一个才会亮灯。
· ZCode：接上时会打开它的 hooks 总开关（不开不跑）；你自己别的 ZCode hook 也会一起开始运行。卸载时还原。
· tb 命令装在 ~/.local/bin。终端里提示找不到 tb 的话，把它加进 PATH：
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc   然后开一个新的终端窗口。
· Chrome 歌词（B 站 / YouTube）：勾了之后会打开 Chrome 的扩展页面和一个选中了 ChromeExtension 文件夹的 Finder 窗口——
  在扩展页面右上角打开「开发者模式」，把那个文件夹拖到扩展页面上。

━━ 隐私 ━━
· 全在本机：只读 Claude 桌面 app 的用量文件、Codex 的登录、AI 会话的状态；不读对话内容，不上传任何东西。
· 联网只有两处：查 Codex 额度（chatgpt.com 的用量接口，用你本机 Codex 的登录）；歌词扩展查歌词（lrclib / 网易云 / 酷狗）。

━━ 卸载 ━━
点菜单栏上的 AIQuota →「接入…」→「卸载 AIQuota…」：去掉 Claude Code / Codex / ZCode 配置里 AIQuota 的条目（先备份）、
AIQuota 装的 tb 命令、开机启动，把 AIQuota 移到废纸篓；可以选连数据一起删。（直接把 app 拖进废纸篓会把这些配置留下。）
也可以双击这个安装盘里的「卸载 AIQuota.command」（第一次同样要到「隐私与安全性」里放行）。

第三方：触控栏钢琴改编自 p-x9/pock-piano-widget（MIT），授权全文在「第三方授权」文件夹里。
EOF

cat > "$STAGE/卸载 AIQuota.command" <<'EOF'
#!/bin/bash
# 卸载 AIQuota：去掉 Claude Code / Codex / ZCode 配置里 AIQuota 的 hooks（先备份）、AIQuota 装的 tb、开机启动，退出并删掉 app。
# 清理用装好的那一份（你已经放行过）；找不到才用安装盘里的。清理没成功就不删 app。
HERE="$(cd "$(dirname "$0")" && pwd)"
APPS=()
for candidate in "/Applications/AIQuota.app" "$HOME/Applications/AIQuota.app"; do [ -d "$candidate" ] && APPS+=("$candidate"); done
TOOL=""
for app in "${APPS[@]}" "$HERE/AIQuota.app"; do
    if [ -x "$app/Contents/MacOS/AIQuota" ]; then TOOL="$app/Contents/MacOS/AIQuota"; break; fi
done
echo "AIQuota 卸载"
echo "会去掉：Claude Code / Codex / ZCode 配置里 AIQuota 的条目（改之前备份）、AIQuota 装的 ~/.local/bin/tb、开机启动，"
echo "并退出、删除：${APPS[*]:-（没找到装好的 AIQuota.app）}"
read -r -p "继续？[y/N] " yes
[[ "$yes" =~ ^[Yy] ]] || { echo "没有改任何东西。"; exit 0; }
read -r -p "连 AIQuota 的数据（设置、常用指令、会话状态）一起删？[y/N] " purge
if [ -z "$TOOL" ]; then
    echo "找不到 AIQuota 程序，没法清理 AI 配置里的条目。没删任何东西。"
    exit 1
fi
for app in "${APPS[@]}"; do pkill -xf "$app/Contents/MacOS/AIQuota" 2>/dev/null || true; done
launchctl bootout "gui/$(id -u)/local.aiquota.menubar" 2>/dev/null || true
if [[ "$purge" =~ ^[Yy] ]]; then "$TOOL" --uninstall --purge; else "$TOOL" --uninstall; fi
status=$?
if [ $status -ne 0 ]; then
    echo ""
    echo "有的配置文件改不了（上面写了是哪个），AIQuota.app 留着没删。处理好之后再运行一次这个卸载。"
    exit 1
fi
for app in "${APPS[@]}"; do rm -rf "$app" && echo "已删除 $app"; done
echo "卸载完了。可以关掉这个窗口。"
EOF
chmod +x "$STAGE/卸载 AIQuota.command"

DMG="$OUT/AIQuota-$DATE-$COMMIT.dmg"
rm -f "$DMG"
hdiutil create -volname "AIQuota" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "已打包：$(cd "$OUT" && pwd)/$(basename "$DMG")（$(du -h "$DMG" | cut -f1)）"
