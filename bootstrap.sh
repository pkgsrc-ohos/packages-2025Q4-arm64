#!/bin/sh
set -e

WORKDIR=$(pwd)
REPOSITORY_OWNER=$GITHUB_REPOSITORY_OWNER
REPOSITORY=$GITHUB_REPOSITORY
PKGSRC_BRANCH="pkgsrc-2025Q4"
PKGSRC_QUARTER="2025Q4"
PKG_PREFIX="/storage/Users/currentUser/.pkg"
PKG_ARCH="arm64"

# 下载 pkgsrc 源码树
cd /opt
git clone --depth 1 -b $PKGSRC_BRANCH "https://github.com/$REPOSITORY_OWNER/pkgsrc.git"

# bootstrap
cd /opt/pkgsrc/bootstrap
./bootstrap \
    --prefix $PKG_PREFIX \
    --varbase $PKG_PREFIX/var \
    --pkgdbdir $PKG_PREFIX/pkgdb \
    --prefer-pkgsrc yes \
    --compiler clang

# 修改个性化配置，让仓库里面所有把 openssl 视为可选依赖的软件包全部启用 openssl
sed -i '/.endif/i PKG_DEFAULT_OPTIONS+=\topenssl' $PKG_PREFIX/etc/mk.conf

# 把“干净”的 .pkg 目录复制一份备份起来
cp -r $PKG_PREFIX $PKG_PREFIX-backup

export MAKEFLAGS="MAKE_JOBS=$(nproc)"
export PATH=$PKG_PREFIX/bin:$PKG_PREFIX/sbin:$PATH

# 需要预置在 bootstrap kit 里面的软件包
PACKAGES="pkgtools/pkgin
security/mozilla-rootcerts"

# 循环构建它们，产生的包会存放在 /opt/pkgsrc/packages/All
# 此时 .pkg 目录里面会带有大量构建期依赖
for pkg in $PACKAGES; do
    cd "/opt/pkgsrc/$pkg"
    bmake package clean
done

# 把这个“脏了”的 .pkg 目录删掉，再把“干净”的 .pkg 目录移回来
rm -r $PKG_PREFIX
mv $PKG_PREFIX-backup $PKG_PREFIX

# 通过二进制安装的方式，把这些预置包装到“干净”的目录里面，
# 此时 .pkg 里面只会携带它们的运行期依赖，不会携带构建期依赖
export PKG_PATH="/opt/pkgsrc/packages/All"
pkg_add pkgin mozilla-rootcerts

# 预置 ssl 证书到 .pkg 目录中，随包分发
mozilla-rootcerts install

# 整体进行一遍代码签名
find $PKG_PREFIX -type f | while read -r FILE; do
    if file -b "$FILE" | grep -iqE "ELF|shared object"; then
        echo ">>> Signing: $FILE"
        binary-sign-tool sign -inFile $FILE -outFile $FILE -selfSign 1
        chmod 0755 $FILE
    fi
done

# 改 pkgin 的配置文件，把默认源设置成 github 链接
REPO_URL="https://github.com/$REPOSITORY_OWNER/packages-$PKGSRC_QUARTER-$PKG_ARCH/releases/download/All"
CONF_FILE="$PKG_PREFIX/etc/pkgin/repositories.conf"
echo $REPO_URL > $CONF_FILE

# 临时编译一个 zip，装到 /bin 目录下，用来打包 zip 格式的 bootstrap kit
# 为保证 bootstarp kit 干净，这里没有用 pkgsrc 源码树里面的 zip，而是自己另拿源码编一个
cd $WORKDIR
curl -fSLO https://downloads.sourceforge.net/project/infozip/Zip%203.x%20%28latest%29/3.0/zip30.tar.gz
tar -zxf zip30.tar.gz
cd zip30
bmake -f unix/Makefile install BINDIR=/bin

# 打包
cd $WORKDIR
tar -zcf "bootstrap-ohos-$PKGSRC_QUARTER-$PKG_ARCH-$(date +%Y%m%d).tar.gz" -C / $PKG_PREFIX
cd /
zip -ryX "$WORKDIR/bootstrap-ohos-$PKGSRC_QUARTER-$PKG_ARCH-$(date +%Y%m%d).zip" $PKG_PREFIX
cd - >/dev/null

# 上传。如果 release 不存在就先创建 release 再上传产物。
gh release view bootstrap --repo "$REPOSITORY" >/dev/null 2>&1 || \
    gh release create bootstrap --repo "$REPOSITORY" --title "bootstrap" --notes "Bootstrap kit（引导套件）"
gh release upload bootstrap bootstrap-ohos-2025Q4-arm64-* --clobber --repo $REPOSITORY
