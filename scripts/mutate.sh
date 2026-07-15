#!/bin/bash
# All OpenWrt tree mutations for the RM1800 build. Shared by CI + local.
# Usage: scripts/mutate.sh <config_name>   e.g. scripts/mutate.sh rm1800-wifi
# Must be run with CWD = the openwrt source tree root.
set -e

CONFIG="${1:-rm1800-wifi}"
# config file: CI passes configs/ in the workflow repo; locally symlinked into ./configs
CONFIG_FILE="${CONFIG_FILE:-configs/${CONFIG}.config}"

echo "=== load seed config ($CONFIG_FILE) ==="
test -f "$CONFIG_FILE" || { echo "::error::config not found: $CONFIG_FILE"; exit 1; }
cp "$CONFIG_FILE" .config

echo "=== strip -Werror from qca-nss-drv ==="
for f in $(grep -rl 'Werror' package/qca-nss/qca-nss-drv/ feeds/*/qca-nss/qca-nss-drv/ 2>/dev/null); do
  echo "de-Werror: $f"; sed -i 's/-Werror[^ ]*//g' "$f"
done
find build_dir -path '*qca-nss-drv*' -name 'Makefile*' -exec sed -i 's/-Werror[^ ]*//g' {} \; 2>/dev/null || true

echo "=== kernel config: non-interactive skb frag ==="
for f in target/linux/generic/config-*; do
  echo '# CONFIG_ALLOC_SKB_PAGE_FRAG_DISABLE is not set' >> "$f"
done
rm -rf build_dir/target-*

echo "=== neuter NSS mac80211 patches ==="
rm -rf package/kernel/mac80211/patches/nss

echo "=== CMA children + 24M reserved-memory node @ 0x46000000 ==="
for f in target/linux/generic/config-*; do
  sed -i '/CONFIG_CMA[ =]/d; /CONFIG_CMA is not set/d; /CONFIG_CMA_/d; /CONFIG_DMA_CMA/d' "$f"
  printf '%s\n' 'CONFIG_CMA=y' 'CONFIG_DMA_CMA=y' \
    '# CONFIG_CMA_DEBUG is not set' '# CONFIG_CMA_DEBUGFS is not set' \
    '# CONFIG_CMA_SYSFS is not set' 'CONFIG_CMA_AREAS=7' \
    'CONFIG_CMA_SIZE_MBYTES=0' 'CONFIG_CMA_SIZE_SEL_MBYTES=y' \
    '# CONFIG_CMA_SIZE_SEL_PERCENTAGE is not set' \
    '# CONFIG_CMA_SIZE_SEL_MIN is not set' \
    '# CONFIG_CMA_SIZE_SEL_MAX is not set' 'CONFIG_CMA_ALIGNMENT=8' >> "$f"
done
DTS=$(find target/linux -iname '*ax1800*.dts' | grep -vi 'gl-\|mt7621' | head -1)
test -n "$DTS" || { echo "::error::AX1800 DTS not found"; exit 1; }
echo "Patching DTS: $DTS"
sed -i 's/ cma=[0-9]*M//g' "$DTS"
grep -q wifi_cma "$DTS" || printf '\n/ {\n\treserved-memory {\n\t\twifi_cma: wifi_cma@46000000 {\n\t\t\tcompatible = "shared-dma-pool";\n\t\t\treusable;\n\t\t\tlinux,cma-default;\n\t\t\treg = <0x0 0x46000000 0x0 0x01800000>;\n\t\t};\n\t};\n};\n' >> "$DTS"

echo "=== NSS: wifi-side off + pin mem profiles ==="
sed -i '/CONFIG_ATH11K_NSS_SUPPORT/d; /CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE/d; /CONFIG_MAC80211_NSS_SUPPORT/d; /CONFIG_PACKAGE_kmod-qca-nss-drv-wifioffload/d; /CONFIG_IPQ_MEM_PROFILE/d; /CONFIG_ATH11K_MEM_PROFILE/d' .config
printf '%s\n' \
  '# CONFIG_ATH11K_NSS_SUPPORT is not set' \
  '# CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE is not set' \
  '# CONFIG_MAC80211_NSS_SUPPORT is not set' \
  '# CONFIG_PACKAGE_kmod-qca-nss-drv-wifioffload is not set' \
  'CONFIG_IPQ_MEM_PROFILE_256=y' \
  'CONFIG_ATH11K_MEM_PROFILE_256M=y' >> .config

echo "=== NSS dataplane trim (keep dp+drv+ssdk, drop ecm+submodules) ==="
for f in target/linux/qualcommax/Makefile target/linux/qualcommax/image/Makefile target/linux/qualcommax/image/ipq60xx.mk; do
  [ -f "$f" ] || continue
  sed -i -E 's/\bkmod-qca-nss-ecm\b//g; s/\bkmod-qca-nss-drv-[a-z0-9-]+\b//g; s/\bkmod-qca-nss-crypto\b//g; s/\bqca-nss-(ecm|clients|crypto)\b//g' "$f"
done
sed -i -E '/^CONFIG_PACKAGE_kmod-qca-nss-ecm[= ]/d' .config
sed -i -E '/^CONFIG_PACKAGE_kmod-qca-nss-drv-[a-z0-9-]+[= ]/d' .config
sed -i -E '/^CONFIG_PACKAGE_kmod-qca-nss-crypto[= ]/d' .config
printf '%s\n' \
  'CONFIG_PACKAGE_kmod-qca-nss-drv=y' \
  'CONFIG_PACKAGE_kmod-qca-nss-dp=y' \
  'CONFIG_PACKAGE_kmod-qca-ssdk=y' \
  '# CONFIG_PACKAGE_kmod-qca-nss-ecm is not set' >> .config

echo "=== defconfig + NSS re-assert ==="
make defconfig
sed -i 's/^CONFIG_ATH11K_NSS_SUPPORT=y$/# CONFIG_ATH11K_NSS_SUPPORT is not set/' .config
sed -i 's/^CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE=y$/# CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE is not set/' .config
sed -i 's/^CONFIG_MAC80211_NSS_SUPPORT=y$/# CONFIG_MAC80211_NSS_SUPPORT is not set/' .config
awk '/^CONFIG_PACKAGE_(kmod-)?qca-nss/ && !/kmod-qca-nss-(dp|drv)[= ]/ { sub(/=y/,""); print "# "$1" is not set"; next } {print}' .config > .config.tmp && mv .config.tmp .config
make defconfig

echo "=== NSS assertions ==="
if grep -qE '^CONFIG_(ATH11K_NSS_SUPPORT|MAC80211_NSS_SUPPORT)=y' .config; then
  echo "::error::wifi NSS still enabled"; exit 1; fi
if grep -E '^CONFIG_PACKAGE_(kmod-)?qca-nss' .config | grep -Eqv 'kmod-qca-nss-(dp|drv)=y'; then
  echo "::error::unexpected NSS pkg:"; grep -E '^CONFIG_PACKAGE_(kmod-)?qca-nss' .config | grep -Ev 'kmod-qca-nss-(dp|drv)=y'; exit 1; fi
echo "✅ NSS trimmed (dp+drv kept for LAN)"

echo "=== monitor rings off (IPQ6018) ==="
make package/kernel/mac80211/{clean,prepare} V=s QUILT=1 2>/dev/null || true
ATH=$(find build_dir -path '*ath11k/core.c' | head -1)
if [ -n "$ATH" ]; then
  awk '/\.hw_rev = ATH11K_HW_IPQ6018_HW10/{i=1} i&&/\.rxdma1_enable = true/{sub(/true/,"false");i=0} {print}' "$ATH" > "$ATH.tmp" && mv "$ATH.tmp" "$ATH"
  grep -n 'IPQ6018_HW10' -A25 "$ATH" | grep rxdma1_enable || true
else
  echo "⚠️ core.c not extracted yet (fine on first pass; re-run picks it up)"
fi
echo "=== mutate.sh done ==="
