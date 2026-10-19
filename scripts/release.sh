#!/bin/zsh
# 发布新版本：改版本号 → Release 编译 → 打 zip → 用 Sparkle 签名并更新 appcast.xml。
# 加 --publish 才会提交、推送并创建 GitHub Release；不加只在本地生成，方便先检查。
#
# 用法：scripts/release.sh 0.2.0 [发布说明.md] [--publish]
# 签名私钥在本机登录钥匙串（Sparkle generate_keys 生成，账户 ed25519）。
set -euo pipefail

cd "$(dirname "$0")/.."

version=""
notes=""
publish=false
for arg in "$@"; do
    case "$arg" in
        --publish) publish=true ;;
        *.md) notes="$arg" ;;
        *) version="$arg" ;;
    esac
done
if [[ -z "$version" ]]; then
    echo "用法：scripts/release.sh <版本号，如 0.2.0> [发布说明.md] [--publish]" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "工作区有未提交的改动，先提交或还原再发版" >&2
    exit 1
fi
if git rev-parse "v$version" >/dev/null 2>&1; then
    echo "标签 v$version 已存在" >&2
    exit 1
fi

repo="fulisadawang/aiphoto"
release_dir="build/release"
updates_dir="$release_dir/updates"
derived="$release_dir/DerivedData"
sparkle_bin="build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"

# 版本号：对外显示用 MARKETING_VERSION；Sparkle 按 CFBundleVersion 比较新旧，每次发版加 1
build=$(( $(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)"/\1/p' project.yml) + 1 ))
sed -i '' "s/^\( *MARKETING_VERSION: \)\".*\"/\1\"$version\"/" project.yml
sed -i '' "s/^\( *CURRENT_PROJECT_VERSION: \)\".*\"/\1\"$build\"/" project.yml
echo "版本 $version（build $build）"

xcodegen generate >/dev/null
xcodebuild -project AIPhoto.xcodeproj -scheme AIPhoto -configuration Release \
    -derivedDataPath "$derived" -clonedSourcePackagesDirPath build/DerivedData/SourcePackages build -quiet
app="$derived/Build/Products/Release/AIPhoto.app"

# 每次只放本次的安装包和现有 appcast.xml，generate_appcast 会在原清单上追加新条目
rm -rf "$updates_dir"
mkdir -p "$updates_dir"
archive="AIPhoto-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$updates_dir/$archive"
[[ -f appcast.xml ]] && cp appcast.xml "$updates_dir/"
[[ -n "$notes" ]] && cp "$notes" "$updates_dir/AIPhoto-$version.md"

"$sparkle_bin/generate_appcast" \
    --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
    --embed-release-notes \
    --maximum-deltas 0 \
    "$updates_dir"
cp "$updates_dir/appcast.xml" appcast.xml
echo "已生成 $updates_dir/$archive 并更新 appcast.xml"

if ! $publish; then
    echo "未发布。检查无误后，还原 project.yml 和 appcast.xml 的改动，再加 --publish 重新运行。"
    exit 0
fi

git add project.yml appcast.xml
git commit -m "发布 v$version

- 版本号改为 $version（build $build）
- appcast.xml 新增 v$version 的更新条目"
git push origin HEAD
# appcast 里的下载地址指向这个 Release 的附件
notes_args=(--generate-notes)
[[ -n "$notes" ]] && notes_args=(--notes-file "$notes")
gh release create "v$version" "$updates_dir/$archive" --repo "$repo" --target "$(git rev-parse HEAD)" \
    --title "v$version" "${notes_args[@]}"
echo "已发布 v$version"
