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

[ "$CONFIG" = "rm1800-wifi" ] && NONSS=1 || NONSS=0
echo "No NSS: $NONSS"

echo "=== strip -Werror from qca-nss-drv ==="
# for p in qca-ssdk qca-nss-dp qca-nss-drv; do
#   make package/qca-nss/$p/clean >/dev/null 2>&1 || true
# done
for f in $(grep -rl 'Werror' package/qca-nss/qca-nss-drv/ feeds/*/qca-nss/qca-nss-drv/ 2>/dev/null); do
  echo "de-Werror: $f"; sed -i 's/-Werror[^ ]*//g' "$f"
done
find build_dir -path '*qca-nss-drv*' -name 'Makefile*' -exec sed -i 's/-Werror[^ ]*//g' {} \; 2>/dev/null || true
echo "=== fix stale clients -Werror patch context ==="
sed -i 's/^ ccflags-y += -Wall$/ ccflags-y += -Wall -Werror/' \
  package/qca-nss/qca-nss-clients/patches/001-compat-build-system-common-headers.patch

# echo "=== strip -Werror from qca-nss ==="
# for f in $(grep -rl 'Werror' package/qca-nss/ feeds/*/qca-nss/ 2>/dev/null); do
#   echo "de-Werror: $f"; sed -i 's/-Werror[^ ]*//g' "$f"
# done
# find build_dir -path '*qca-nss*' -name 'Makefile*' -exec sed -i 's/-Werror[^ ]*//g' {} \; 2>/dev/null || true

# echo "=== kernel config: non-interactive skb frag ==="
# for f in target/linux/generic/config-*; do
#   echo '# CONFIG_ALLOC_SKB_PAGE_FRAG_DISABLE is not set' >> "$f"
# done
if [ -n "$GITHUB_ACTIONS" ]; then
  echo "CI detected → full target rebuild"
  rm -rf build_dir/target-*
else
  # rm -rf build_dir/target-*
  echo "local → keeping build_dir for incremental"
fi

if [ $NONSS = 1 ]; then
  echo "=== neuter NSS mac80211 patches ==="
  rm -rf package/kernel/mac80211/patches/nss
fi

if [ $NONSS = 1 ]; then
  echo "=== CMA children + 16M reserved-memory node @ 0x46000000 ==="
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
  echo "=== CMA reserved-memory node (idempotent) ==="
  DTS=$(find target/linux -iname '*ax1800*.dts' | grep -vi 'gl-\|mt7621' | head -1)
  test -n "$DTS" || { echo "::error::AX1800 DTS not found"; exit 1; }
  echo "Patching DTS: $DTS"
  sed -i 's/ cma=[0-9]*M//g' "$DTS"
  # remove ANY previously-injected block (marker-delimited) so we never stack/keep stale nodes
  sed -i '/\/\* RM1800-CMA-BEGIN \*\//,/\/\* RM1800-CMA-END \*\//d' "$DTS"
  # also strip any bare wifi_cma node from older script versions (no marker)
  sed -i '/wifi_cma@[0-9a-f]* {/,/};/d' "$DTS"
  # add the current one, marker-wrapped
  cat >> "$DTS" <<'EOF'
/* RM1800-CMA-BEGIN */
/ {
	reserved-memory {
		wifi_cma: wifi_cma@46000000 {
			compatible = "shared-dma-pool";
			reusable;
			linux,cma-default;
			reg = <0x0 0x46000000 0x0 0x01000000>;
		};
	};
};
/* RM1800-CMA-END */
EOF
  grep -A8 'RM1800-CMA-BEGIN' "$DTS"   # echo what actually landed
    # --- ath11k FW memory mode: force mode 1 (coldboot cal on) ---
  MODE_DTS=$(find target/linux -iname 'ipq6000-ax1800.dts' | head -1)
  sed -i 's/qcom,ath11k-fw-memory-mode = <[0-9]>;/qcom,ath11k-fw-memory-mode = <1>;/' "$MODE_DTS"
  grep -n 'fw-memory-mode' "$DTS"   # must print <2>

  make target/linux/clean 2>/dev/null || true
fi

if [ $NONSS = 1 ]; then
  echo "=== NSS: wifi-side off"
  sed -i '/CONFIG_ATH11K_NSS_SUPPORT/d; /CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE/d; /CONFIG_MAC80211_NSS_SUPPORT/d; /CONFIG_PACKAGE_kmod-qca-nss-drv-wifioffload/d' .config
  printf '%s\n' \
    '# CONFIG_ATH11K_NSS_SUPPORT is not set' \
    '# CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE is not set' \
    '# CONFIG_MAC80211_NSS_SUPPORT is not set' \
    '# CONFIG_PACKAGE_kmod-qca-nss-drv-wifioffload is not set' >> .config
fi

echo "=== Pin mem profiles ==="
sed -i '/CONFIG_IPQ_MEM_PROFILE/d; /CONFIG_ATH11K_MEM_PROFILE/d' .config
printf '%s\n' \
  'CONFIG_IPQ_MEM_PROFILE_256=y' \
  'CONFIG_ATH11K_MEM_PROFILE_256M=y' >> .config

if [ $NONSS = 1 ]; then
  echo "=== NSS dataplane: standalone dp+ssdk, DROP drv/core/firmware ==="
  for f in target/linux/qualcommax/Makefile target/linux/qualcommax/image/Makefile target/linux/qualcommax/image/ipq60xx.mk; do
  [ -f "$f" ] || continue
  sed -i -E 's/\bkmod-qca-nss-drv\b//g; s/\bqca-nss-drv\b//g; s/\bnss-firmware-ipq60xx\b//g; s/\bkmod-qca-nss-ecm\b//g; s/\bkmod-qca-nss-drv-[a-z0-9-]+\b//g; s/\bkmod-qca-nss-crypto\b//g; s/\bqca-nss-(ecm|clients|crypto)\b//g' "$f"
  done
  # de-couple dp from drv → match mainline dep (@TARGET_qualcommax +kmod-qca-ssdk)
  for f in $(find package feeds -path '*qca-nss-dp/Makefile' 2>/dev/null); do
  sed -i -E 's/\+kmod-qca-nss-drv//g; s/\+qca-nss-drv//g' "$f"
  done
  sed -i -E '/^CONFIG_PACKAGE_(kmod-)?qca-nss-drv([= ]|-)/d' .config
  sed -i -E '/^CONFIG_PACKAGE_kmod-qca-nss-ecm[= ]/d' .config
  sed -i -E '/^CONFIG_PACKAGE_kmod-qca-nss-crypto[= ]/d' .config
  sed -i -E '/^CONFIG_PACKAGE_nss-firmware-ipq60xx[= ]/d' .config
  printf '%s\n' \
  'CONFIG_PACKAGE_kmod-qca-nss-dp=y' \
  'CONFIG_PACKAGE_kmod-qca-ssdk=y' \
  '# CONFIG_PACKAGE_kmod-qca-nss-drv is not set' \
  '# CONFIG_PACKAGE_qca-nss-drv is not set' \
  '# CONFIG_PACKAGE_kmod-qca-nss-ecm is not set' \
  '# CONFIG_PACKAGE_nss-firmware-ipq60xx is not set' >> .config
fi

# echo "=== strip unused USB host stack + qcserial + automount (RM1800 has no USB) ==="
# MK=target/linux/qualcommax/Makefile
# sed -i -E 's/\bkmod-usb-dwc3-qcom\b//g; s/\bkmod-usb-serial-qualcomm\b//g; s/\bkmod-usb-dwc3\b//g; s/\bkmod-usb3\b//g; s/\bautomount\b//g' "$MK"
# sed -i -E '/^CONFIG_PACKAGE_kmod-usb(3|-dwc3|-dwc3-qcom|-serial-qualcomm)[= ]/d; /^CONFIG_PACKAGE_automount[= ]/d; /^CONFIG_PACKAGE_kmod-usb-storage[0-9a-z-]*[= ]/d' .config
# printf '%s\n' \
#   '# CONFIG_PACKAGE_automount is not set' \
#   '# CONFIG_PACKAGE_kmod-usb3 is not set' \
#   '# CONFIG_PACKAGE_kmod-usb-dwc3 is not set' \
#   '# CONFIG_PACKAGE_kmod-usb-dwc3-qcom is not set' \
#   '# CONFIG_PACKAGE_kmod-usb-serial-qualcomm is not set' >> .config
# sed -i -E '/^CONFIG_PACKAGE_kmod-usb-(core|common)[= ]/d' .config
# printf '%s\n' \
#   '# CONFIG_PACKAGE_kmod-usb-core is not set' \
#   '# CONFIG_PACKAGE_kmod-usb-common is not set' >> .config


if [ $NONSS = 1 ]; then
  echo "=== defconfig + NSS re-assert ==="
  make defconfig
  sed -i 's/^CONFIG_ATH11K_NSS_SUPPORT=y$/# CONFIG_ATH11K_NSS_SUPPORT is not set/' .config
  sed -i 's/^CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE=y$/# CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE is not set/' .config
  sed -i 's/^CONFIG_MAC80211_NSS_SUPPORT=y$/# CONFIG_MAC80211_NSS_SUPPORT is not set/' .config
  awk '/^CONFIG_PACKAGE_(kmod-)?qca-nss/ && !/kmod-qca-nss-dp[= ]/ { sub(/=y/,""); print "# "$1" is not set"; next } {print}' .config > .config.tmp && mv .config.tmp .config
  make defconfig

  echo "=== NSS assertions ==="
  if grep -qE '^CONFIG_(ATH11K_NSS_SUPPORT|MAC80211_NSS_SUPPORT)=y' .config; then
    echo "::error::wifi NSS still enabled"; exit 1; fi
  if grep -qE '^CONFIG_PACKAGE_(kmod-)?qca-nss-drv=y' .config; then
  echo "::error::qca-nss-drv still enabled after strip"; exit 1; fi
  if grep -E '^CONFIG_PACKAGE_(kmod-)?qca-nss' .config | grep -Eqv 'kmod-qca-nss-dp=y'; then
  echo "::error::unexpected NSS pkg:"; grep -E '^CONFIG_PACKAGE_(kmod-)?qca-nss' .config | grep -Ev 'kmod-qca-nss-dp=y'; exit 1; fi
  echo "✅ NSS trimmed to standalone dp+ssdk (no drv/core)"
else
  make defconfig
fi
if grep -E '^CONFIG_PACKAGE_kmod-usb[0-9a-z-]*=y' .config | grep -qvE 'kmod-usb-(core|common)=y'; then
  echo "::error::real USB kmod still enabled"; exit 1; fi


# echo "=== ath11k IPQ6018: mon rings off + coldboot cal off ==="
# ATH=$(find build_dir -path '*ath11k/core.c' | head -1)
# if [ -n "$ATH" ]; then
#   awk '/\.hw_rev = ATH11K_HW_IPQ6018_HW10/{i=1}
#        i&&/\.rxdma1_enable = true/{sub(/true/,"false")}
#        i&&/\.coldboot_cal_mm = true/{sub(/true/,"false")}
#        i&&/\.coldboot_cal_ftm = true/{sub(/true/,"false");i=0}
#        {print}' "$ATH" > "$ATH.tmp" && mv "$ATH.tmp" "$ATH"
#   grep -n 'IPQ6018_HW10' -A25 "$ATH" | grep -E 'rxdma1_enable|coldboot_cal'
# else
#   echo "⚠️ core.c not extracted yet (fine on first pass; re-run picks it up)"
# fi

# echo "=== ath11k IPQ6018: mon rings off + coldboot cal off ==="
# make package/kernel/mac80211/prepare V=s QUILT=0   # guarantee core.c is extracted
# ATH=$(find build_dir -path '*ath11k/core.c' | head -1)
# [ -n "$ATH" ] || { echo "::error::ath11k core.c not found after prepare"; exit 1; }

# awk '/\.hw_rev = ATH11K_HW_IPQ6018_HW10/{i=1}
#      i&&/\.rxdma1_enable = true/{sub(/true/,"false")}
#      i&&/\.coldboot_cal_mm = true/{sub(/true/,"false")}
#      i&&/\.coldboot_cal_ftm = true/{sub(/true/,"false");i=0}
#      {print}' "$ATH" > "$ATH.tmp" && mv "$ATH.tmp" "$ATH"

# # HARD verify — fail the build if mon-off didn't land
# if grep -n -A25 'IPQ6018_HW10' "$ATH" | grep -q 'rxdma1_enable = true'; then
#     echo "::error::rxdma1_enable still true — mon-off patch did NOT apply"; exit 1
# fi
# grep -n -A25 'IPQ6018_HW10' "$ATH" | grep -E 'rxdma1_enable|coldboot_cal'

make package/kernel/mac80211/prepare V=s
ATH=$(find build_dir -path '*ath11k/core.c' | head -1)
cp "$ATH" "$ATH.orig"
awk '/\.hw_rev = ATH11K_HW_IPQ6018_HW10/{i=1}
     i&&/\.rxdma1_enable = true/{sub(/true/,"false")}
     i&&/\.coldboot_cal_mm = true/{sub(/true/,"false")}
     i&&/\.coldboot_cal_ftm = true/{sub(/true/,"false");i=0}
     {print}' "$ATH.orig" > "$ATH"
diff -u "$ATH.orig" "$ATH" \
  | sed 's|.*core\.c\.orig|--- a/drivers/net/wireless/ath/ath11k/core.c|; s|.*/core\.c$|+++ b/drivers/net/wireless/ath/ath11k/core.c|' \
  > package/kernel/mac80211/patches/ath11k/999-rm1800-mon-off.patch



# echo "=== ath11k: shrink DP RX ring sizes (RAM footprint) ==="
# DPH=$(find build_dir -path '*ath11k/dp.h' | head -1)
# if [ -n "$DPH" ]; then
#   sed -i -E 's/(#define[[:space:]]+DP_RXDMA_BUF_RING_SIZE[[:space:]]+)[0-9]+/\11024/' "$DPH"
#   sed -i -E 's/(#define[[:space:]]+DP_RXDMA_REFILL_RING_SIZE[[:space:]]+)[0-9]+/\1512/' "$DPH"
#   grep -E 'DP_RXDMA_(BUF|REFILL)_RING_SIZE' "$DPH"
# fi


echo "=== stamp build-id ==="
SHA=$(git -C . rev-parse --short HEAD 2>/dev/null || echo "nogit")
if [ -n "$GITHUB_ACTIONS" ]; then
  RUN="${GITHUB_RUN_ID}"
  BUILT_BY="ci"
else
  RUN="local-$(date +%s)"
  BUILT_BY="wsl-$(whoami)@$(hostname)"
fi
mkdir -p files/etc
cat > files/etc/build-id <<EOF
os=ImmortalWrt
config=${CONFIG}
sha=${SHA}
run_id=${RUN}
built_by=${BUILT_BY}
built=$(date -u +%FT%TZ)
notes="2.12 ddwrt firmware (dual-radio fix); NSS wifi-off + standalone dp; CMA 16M @0x46000000; DTS_Mode 1 Rings Mon off by patch; Usb; mdns; Rings not shrunk"
EOF
cat files/etc/build-id

echo "=== mutate.sh done ==="
