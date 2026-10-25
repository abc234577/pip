#!/usr/bin/env bash
# 把下载好的免签名 IPA 通过 SSH 装到越狱 / TrollStore 设备。
# 用法: ./install-via-ssh.sh ScreenViewer-unsigned.ipa 192.168.1.50 root
set -euo pipefail

IPA="${1:?用法: install-via-ssh.sh <ipa路径> <手机IP> [用户名=root]}"
HOST="${2:?缺手机 IP}"
USER="${3:-root}"

echo "[*] 传 IPA 到手机 /var/mobile/Media/ ..."
scp -O "$IPA" "$USER@$HOST:/var/mobile/Media/install.ipa"

echo "[*] 若装了 TrollStore, 用 trollstorehelper 安装:"
ssh "$USER@$HOST" '
  if command -v trollstorehelper >/dev/null 2>&1; then
    trollstorehelper install /var/mobile/Media/install.ipa
  elif [ -x /var/containers/Bundle/Application/*/TrollStore.app/trollstorehelper ]; then
    HELPER=$(ls /var/containers/Bundle/Application/*/TrollStore.app/trollstorehelper | head -n1)
    "$HELPER" install /var/mobile/Media/install.ipa
  else
    echo "未找到 trollstorehelper。请在手机上打开 TrollStore -> 右上角 + -> 选 install.ipa 手动安装。"
  fi
'
echo "[*] 完成。桌面上应出现 ScreenViewer 图标。"
