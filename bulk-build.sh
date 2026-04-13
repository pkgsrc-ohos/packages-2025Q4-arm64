#!/bin/sh
set -e

# --- 1. 初始化基础变量 ---
WORKDIR=$(pwd)
REPOSITORY_OWNER=$GITHUB_REPOSITORY_OWNER
REPOSITORY=$GITHUB_REPOSITORY
PKGSRC_BRANCH="pkgsrc-2025Q4"
PKGSRC_QUARTER="2025Q4"
PKG_PREFIX="/storage/Users/currentUser/.pkg"
PKG_ARCH="arm64"
INDEX_GZ="pkg_summary.gz"     # gzip 格式的索引文件，用于上传/下载
INDEX_TXT="pkg_summary"       # 文本格式的索引文件，用于本地操作
INDEX_TMP="pkg_summary.tmp"   # 重建索引时的临时文件
PMETA_TMP="package-meta.tmp"  # 包元数据临时文件，里面是单个包的元数据

# --- 2. 准备构建环境 ---
echo ">>> [SETUP] Cloning pkgsrc tree (branch: $PKGSRC_BRANCH)..."
cd /opt
git clone --depth 1 -b "$PKGSRC_BRANCH" https://github.com/$REPOSITORY_OWNER/pkgsrc.git

echo ">>> [SETUP] Finding the latest bootstrap kit..."

LATEST_BOOTSTRAP=$(gh release view bootstrap \
    --repo "$REPOSITORY" \
    --json assets \
    --template '{{range .assets}}{{.name}}{{"\n"}}{{end}}' | \
    grep 'bootstrap-ohos-.*\.tar\.gz$' | \
    sort -r | head -n 1)
if [ -z "$LATEST_BOOTSTRAP" ]; then
    echo ">>> [ERROR] No valid .tar.gz bootstrap found."
    exit 1
fi
echo ">>> [SETUP] Downloading latest: $LATEST_BOOTSTRAP"
gh release download bootstrap \
    --repo "$REPOSITORY" \
    --pattern "$LATEST_BOOTSTRAP" \
    --clobber
tar -zxf bootstrap-ohos-*.tar.gz -C /

cd "$WORKDIR"

export PATH=$PKG_PREFIX/bin:$PKG_PREFIX/sbin:$PATH
sed -i '/.endif/i OHOS_CODE_SIGN+=\tyes' $PKG_PREFIX/etc/mk.conf
export MAKEFLAGS="MAKE_JOBS=$(nproc)"

# --- 3. 验证 Release 状态 ---
echo ">>> [INIT] Checking releases"
gh release view All --repo "$REPOSITORY" >/dev/null 2>&1 || \
    gh release create All --repo "$REPOSITORY" --title "All" --notes "制品仓库"

# --- 4. 下载包索引 ---
echo ">>> [SYNC] Fetching existing index $INDEX_GZ ..."
if gh release download All --repo "$REPOSITORY" --pattern "$INDEX_GZ" --clobber 2>/dev/null; then
    echo ">>> [SYNC] Successfully loaded $INDEX_GZ. Decompressing..."
    gzip -df "$INDEX_GZ"
else
    echo ">>> [SYNC] No existing index found. Starting fresh."
    : > "$INDEX_TXT"
fi

# --- 5. 预取远程 Asset 列表---
echo ">>> [INIT] Pre-fetching remote asset list..."
REMOTE_ASSETS_TMP="$WORKDIR/remote_assets.lst"
gh release view All --repo "$REPOSITORY" \
    --json assets \
    --template '{{range .assets}}{{.name}}{{"\n"}}{{end}}' > "$REMOTE_ASSETS_TMP" 2>/dev/null || : > "$REMOTE_ASSETS_TMP"

# --- 6. 核心构建循环 ---
TARGET_LIST=$(cat $WORKDIR/whitelist.txt)
for p_path in $TARGET_LIST; do

    cd "/opt/pkgsrc/$p_path"

    # 获取包属性：P_NAME(带版本号), P_BASE(包名), P_TGZ(制品路径)
    P_NAME=$(bmake show-var VARNAME=PKGNAME)
    P_BASE=$(bmake show-var VARNAME=PKGBASE)
    P_TGZ="/opt/pkgsrc/packages/All/$P_NAME.tgz"

    # 版本检查：如果当前版本已存在索引和 Asset，则跳过构建
    if grep -q "^PKGNAME=$P_NAME$" "$WORKDIR/$INDEX_TXT" && grep -q "^$P_NAME.tgz$" "$REMOTE_ASSETS_TMP"; then
        echo ">>> [SKIP] $P_NAME is already up-to-date."
        cd "$WORKDIR"
        continue
    fi

    # 依赖预下载，避免实时构建占用大量时间
    # 安装失败不退出，因为还有实时构建作为兜底
    echo ">>> [PRE-FETCH] Quick-installing dependencies for $P_NAME..."
    RAW_DEPS=$(bmake show-depends-recursive 2>/dev/null)
    if [ -n "$RAW_DEPS" ]; then
        pkgin -y update || true
        for dep_path in $RAW_DEPS; do
            FULL_DEP_PATH="/opt/pkgsrc/$dep_path"
            if [ -d "$FULL_DEP_PATH" ]; then
                DEP_BASE=$(cd "$FULL_DEP_PATH" && bmake show-var VARNAME=PKGBASE)
                pkgin -y install "$DEP_BASE" || true
            fi
        done
    fi

    # 执行构建，失败则跳过，去构建下一个包
    echo ">>> [BUILD] Compiling $P_NAME..."
    if ! bmake package clean; then
        echo ">>> [ERROR] Build failed for $P_NAME."
        cd "$WORKDIR"
        continue
    fi

    # 验证制品生成结果
    if [ ! -f "$P_TGZ" ]; then
        echo ">>> [ERROR] $P_NAME compiled, but $P_TGZ is missing."
        cd "$WORKDIR"
        continue
    fi

    # 上传制品包
    echo ">>> [UPLOAD] Binary: $P_TGZ"
    gh release upload All "$P_TGZ" --repo "$REPOSITORY" --clobber

    # 更新包索引：把这个包的元数据添加到包索引中，如果这个包之前已经存在于包索引中就先删掉再重新添加。
    pkg_info -X "$P_TGZ" > "$WORKDIR/$PMETA_TMP"
    awk -v pbase="$P_BASE" '
        BEGIN { RS = ""; ORS = "\n\n" }
        {
            if ($0 ~ "(^|\n)PKGNAME=" pbase "-[0-9]+") {
                next 
            }
            print $0
        }' "$WORKDIR/$INDEX_TXT" > "$WORKDIR/$INDEX_TMP"
    cat "$WORKDIR/$PMETA_TMP" >> "$WORKDIR/$INDEX_TMP"
    mv "$WORKDIR/$INDEX_TMP" "$WORKDIR/$INDEX_TXT"
    gzip -c "$WORKDIR/$INDEX_TXT" > "$WORKDIR/$INDEX_GZ"

    # 上传更新后的包索引
    echo ">>> [UPLOAD] Index: $INDEX_GZ"
    gh release upload All "$WORKDIR/$INDEX_GZ" --repo "$REPOSITORY" --clobber

    echo ">>> [SUCCESS] $P_NAME is uploaded."

    # 返回工作目录，开启下一轮构建
    cd $WORKDIR
done
