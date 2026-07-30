#!/bin/bash
# All OpenWrt tree mutations for the RM1800 build. Shared by CI + local.
# Usage: scripts/mutate.sh <config_name>   e.g. scripts/mutate.sh rm1800-wifi
# Must be run with CWD = the openwrt source tree root.
set -e

CONFIG="${1:-rm1800-wifi}"
# config file: CI passes configs/ in the workflow repo; locally symlinked into ./configs
# CONFIG_FILE="${CONFIG_FILE:-configs/${CONFIG}.config}"
# MON_OFF_PATCH="${MON_OFF_PATCH:-patches/999-rm1800-ipq6018-mon-off.patch}"
# RING_SHRINK_PATCH="${RING_SHRINK_PATCH:-patches/999-999-rm1800-rxdma-buf-2048.patch}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CONFIG_FILE="${CONFIG_FILE:-$REPO_DIR/configs/${CONFIG}.config}"
MON_OFF_PATCH="${MON_OFF_PATCH:-$REPO_DIR/patches/999-rm1800-ipq6018-mon-off.patch}"
RING_SHRINK_PATCH="${RING_SHRINK_PATCH:-$REPO_DIR/patches/999-999-rm1800-rxdma-buf-2048.patch}"

MON_OFF=1   # 0 = skip mon-off (test mode-2 alone first); 1 = apply the patch
CMA_MAINSTREAM=1  # 0 = skip CMA reserved-memory node; 1 = inject it (idempotent)
ATH11K_MEM_PROFILE=512   # 256 or 512; 512 = upstream NSS default (ath.mk:76)

echo "=== load seed config ($CONFIG_FILE) ==="
test -f "$CONFIG_FILE" || { echo "::error::config not found: $CONFIG_FILE"; exit 1; }
cp "$CONFIG_FILE" .config

[ "$CONFIG" = "rm1800-wifi" ] && NONSS=1 || NONSS=0
RINGS_SHRINK=0 # 512M profile already shrinks the rings; 1 = apply the 2048 patch (for 256M profile)
NO_USB=1
DTS_MODE=2
PBUF_SHRINK=0  # 1 = apply the pbuf shrink (for ~148MB MemTotal); 0 = skip it
echo "No NSS: $NONSS; Rings shrunk: $RINGS_SHRINK; No USB: $NO_USB"

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

# if [ $NONSS = 1 ]; then
#   echo "=== neuter NSS mac80211 patches ==="
#   rm -rf package/kernel/mac80211/patches/nss
# fi

echo "=== switch board to 256m memory profile dtsi ==="
XIAOMI_DTSI=target/linux/qualcommax/dts/ipq6000-xiaomi.dtsi
test -f "$XIAOMI_DTSI" || { echo "::error::xiaomi dtsi not found"; exit 1; }
git checkout -- "$XIAOMI_DTSI"
sed -i 's|#include "ipq6018.dtsi"|#include "ipq6018-256m.dtsi"|' "$XIAOMI_DTSI"
grep -n 'include "ipq6018' "$XIAOMI_DTSI"


CMA_SIZE=0
# if [ $NONSS = 1 ]; then
  echo "=== CMA children + ${CMA_SIZE}M reserved-memory node @ 0x46000000 ==="
  for f in target/linux/generic/config-*; do
    sed -i '/CONFIG_CMA[ =]/d; /CONFIG_CMA is not set/d; /CONFIG_CMA_/d; /CONFIG_DMA_CMA/d' "$f"
    printf '%s\n' 'CONFIG_CMA=y' 'CONFIG_DMA_CMA=y' \
      '# CONFIG_CMA_DEBUG is not set' '# CONFIG_CMA_DEBUGFS is not set' \
      '# CONFIG_CMA_SYSFS is not set' 'CONFIG_CMA_AREAS=7' \
      "CONFIG_CMA_SIZE_MBYTES=${CMA_SIZE}" 'CONFIG_CMA_SIZE_SEL_MBYTES=y' \
      '# CONFIG_CMA_SIZE_SEL_PERCENTAGE is not set' \
      '# CONFIG_CMA_SIZE_SEL_MIN is not set' \
      '# CONFIG_CMA_SIZE_SEL_MAX is not set' 'CONFIG_CMA_ALIGNMENT=8' >> "$f"
    printf '%s\n' 'CONFIG_CMA=y' 'CONFIG_DMA_CMA=y' \
      '# CONFIG_CMA_DEBUG is not set' '# CONFIG_CMA_DEBUGFS is not set' \
      '# CONFIG_CMA_SYSFS is not set' 'CONFIG_CMA_AREAS=7' \
      'CONFIG_CMA_ALIGNMENT=8' >> "$f"
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
  if [ $CMA_MAINSTREAM = 0 ]; then
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
  else

    # 3. AX1800 DTS: include the 256M profile (idempotent) + force mode 2
    MODE_DTS=$(find target/linux -iname 'ipq6000-ax1800.dts' | head -1)

    # make sure the OLD custom node is truly gone
    ! grep -q 'wifi_cma@46000000' "$MODE_DTS" || { echo "::error::stale wifi_cma node still present"; exit 1; }

  fi
    # --- ath11k FW memory mode: force mode 1 (coldboot cal on) ---
  MODE_DTS=$(find target/linux -iname 'ipq6000-ax1800.dts' | head -1)
  sed -i "s/qcom,ath11k-fw-memory-mode = <[0-9]>;/qcom,ath11k-fw-memory-mode = <$DTS_MODE>;/" "$MODE_DTS"
  grep -n 'fw-memory-mode' "$MODE_DTS"

  # make target/linux/clean 2>/dev/null || true
  # instead of target/linux/clean, just nuke the built DTB so it regenerates:
  find build_dir -path '*linux-qualcommax*' -name '*ax1800*.dtb' -delete

# fi

if [ $NONSS = 1 ]; then
  echo "=== NSS: wifi-side off"
  sed -i '/CONFIG_ATH11K_NSS_SUPPORT/d; /CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE/d; /CONFIG_MAC80211_NSS_SUPPORT/d; /CONFIG_PACKAGE_kmod-qca-nss-drv-wifioffload/d' .config
  printf '%s\n' \
    '# CONFIG_ATH11K_NSS_SUPPORT is not set' \
    '# CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE is not set' \
    '# CONFIG_MAC80211_NSS_SUPPORT is not set' \
    '# CONFIG_PACKAGE_kmod-qca-nss-drv-wifioffload is not set' >> .config
else
  echo "=== NSS: wifi-side ON"
  printf '%s\n' \
    'CONFIG_ATH11K_NSS_SUPPORT=y' \
    'CONFIG_MAC80211_NSS_SUPPORT=y' \
    'CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE=y' >> .config

fi

# echo "=== Pin mem profiles ==="
# sed -i '/CONFIG_IPQ_MEM_PROFILE/d; /CONFIG_ATH11K_MEM_PROFILE/d' .config
# printf '%s\n' \
#   'CONFIG_IPQ_MEM_PROFILE_256=y' \
#   'CONFIG_ATH11K_MEM_PROFILE_256M=y' >> .config

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

if [ $NO_USB = 1 ]; then
  echo "=== strip unused USB host stack + qcserial + automount (RM1800 has no USB) ==="
  MK=target/linux/qualcommax/Makefile
  sed -i -E 's/\bkmod-usb-dwc3-qcom\b//g; s/\bkmod-usb-serial-qualcomm\b//g; s/\bkmod-usb-dwc3\b//g; s/\bkmod-usb3\b//g; s/\bautomount\b//g' "$MK"
  sed -i -E '/^CONFIG_PACKAGE_kmod-usb(3|-dwc3|-dwc3-qcom|-serial-qualcomm)[= ]/d; /^CONFIG_PACKAGE_automount[= ]/d; /^CONFIG_PACKAGE_kmod-usb-storage[0-9a-z-]*[= ]/d' .config
  printf '%s\n' \
    '# CONFIG_PACKAGE_automount is not set' \
    '# CONFIG_PACKAGE_kmod-usb3 is not set' \
    '# CONFIG_PACKAGE_kmod-usb-dwc3 is not set' \
    '# CONFIG_PACKAGE_kmod-usb-dwc3-qcom is not set' \
    '# CONFIG_PACKAGE_kmod-usb-serial-qualcomm is not set' >> .config
  sed -i -E '/^CONFIG_PACKAGE_kmod-usb-(core|common)[= ]/d' .config
  printf '%s\n' \
    '# CONFIG_PACKAGE_kmod-usb-core is not set' \
    '# CONFIG_PACKAGE_kmod-usb-common is not set' >> .config
fi

echo "=== drop wpad-openssl from qualcommax DEFAULT_PACKAGES ==="
sed -i -E 's/\bwpad-openssl\b//g' target/linux/qualcommax/Makefile
# scrub the generated defaults too, then let defconfig re-pick mbedtls
sed -i -E '/^CONFIG_(DEFAULT|MODULE_DEFAULT)_wpad-openssl[= ]/d' .config


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


# TODO: remove the following once the above is stable and we can rely on defconfig to keep them off:
# after `make defconfig`, assert removed pkgs stayed off:
for s in ttyd libwebsockets-full freeradius3 wpad wpad-mini wpad-openssl \
         wpad-wolfssl wpad-basic-wolfssl libopenssl; do
  grep -q "^# CONFIG_PACKAGE_${s} is not set" .config \
    && echo "OK  $s off" || echo "!!  $s got reselected"
done
# and assert the ones we WANT on:
for s in wpad-basic-mbedtls ddns-go miniupnpd-nftables luci-app-upnp; do
  grep -q "^CONFIG_PACKAGE_${s}=y" .config \
    && echo "OK  $s on" || echo "!!  $s missing"
done

echo "=== ath11k mem profile → ${ATH11K_MEM_PROFILE}M ==="
ATH_MK=package/kernel/mac80211/ath.mk
git checkout -- "$ATH_MK"          # reset to pristine so reruns can't stack
if [ "$ATH11K_MEM_PROFILE" = 256 ]; then
  sed -i 's/ATH11K_MEM_PROFILE_512M/ATH11K_MEM_PROFILE_256M/g' "$ATH_MK"
fi
grep -n 'ATH11K_MEM_PROFILE' "$ATH_MK" || true

git checkout -- package/kernel/mac80211/patches/nss/
if [ "$RINGS_SHRINK" = 1 ]; then
  if [ $NONSS = 1 ]; then
    echo "::error::ring-shrink context is tuned for the NSS series (post 999-233); regenerate for non-NSS"; exit 1
  fi
  RING_DEST=package/kernel/mac80211/patches/nss/ath11k
  echo "=== install rxdma-buf ring-shrink patch (4096→2048) → $RING_DEST ==="
  test -f "$RING_SHRINK_PATCH" || { echo "::error::patch not found: $RING_SHRINK_PATCH"; exit 1; }
  find package/kernel/mac80211/patches -name '999-*rm1800-rxdma-buf-*.patch' -delete
  cp "$RING_SHRINK_PATCH" "$RING_DEST/"
  make package/kernel/mac80211/{clean,prepare} V=s
  DPH=$(find build_dir -path '*mac80211-regular*ath11k/dp.h' | head -1)
  test -n "$DPH" || { echo "::error::prepared dp.h not found"; exit 1; }
  grep -qE '^#define DP_RXDMA_BUF_RING_SIZE[[:space:]]+2048' "$DPH" \
    || { echo "::error::ring-shrink did NOT apply"; exit 1; }
  if find build_dir -name '*.rej' | grep -q . ; then echo "::error::rejects:"; find build_dir -name '*.rej'; exit 1; fi
  echo "OK ring-shrink 2048 landed at $DPH"
fi

DEST=package/kernel/mac80211/patches/nss/ath11k
# clear any stale auto-generated variant so we don't apply two
rm -f "$DEST"/999-rm1800-ipq6018-mon-off.patch
if [ "$MON_OFF" = 1 ]; then
  echo "=== install mon-off patch (ipq6018 rxdma1_enable=false) ==="
  find package/kernel/mac80211/patches -name '999-*rm1800-*.patch' -delete
  test -f "$MON_OFF_PATCH" || { echo "::error::patch not found: $MON_OFF_PATCH"; exit 1; }
    cp "$MON_OFF_PATCH" "$DEST/"
    
  # make package/kernel/mac80211/prepare V=s
  make package/kernel/mac80211/prepare V=s 2>&1 | grep -iE 'Applying|999-rm1800|\.rej|FAILED'
  # want: "Applying .../999-rm1800-ipq6018-mon-off.patch"
  # any ".rej" or "FAILED" = it didn't apply
    CORE=$(find build_dir -path '*mac80211-regular*ath11k/core.c' | head -1)
  test -n "$CORE" || { echo "::error::prepared core.c not found"; exit 1; }
  grep -A60 'ipq6018 hw1\.0' "$CORE" | grep -q '\.rxdma1_enable = false,' \
    || { echo "::error::mon-off did NOT apply"; exit 1; }
  if find build_dir -name '*.rej' | grep -q . ; then echo "::error::rejects:"; find build_dir -name '*.rej'; exit 1; fi
  echo "OK mon-off landed at $CORE"
  make package/kernel/mac80211/compile V=s

else
  echo "=== mon-off DISABLED (testing fw-memory-mode alone) ==="
  rm -f "$DEST"/999-rm1800-ipq6018-mon-off.patch
fi

MCFG=$(find build_dir -path '*mac80211-regular*/backports-*/.config' | head -1)
test -n "$MCFG" || { echo "::error::module .config not found"; exit 1; }
grep -qE "^CPTCFG_ATH11K_MEM_PROFILE_${ATH11K_MEM_PROFILE}M=y" "$MCFG" \
  || { echo "::error::mem profile ${ATH11K_MEM_PROFILE}M did NOT land:"; \
       grep -E 'CPTCFG_ATH11K_MEM_PROFILE' "$MCFG" || true; exit 1; }
echo "OK ath11k mem profile ${ATH11K_MEM_PROFILE}M"


echo "=== bake memory/perf tuning (uci-defaults) ==="
mkdir -p files/etc/uci-defaults files/etc/sysctl.d

# conntrack cap (real file, re-applied every boot by S11sysctl)
cat > files/etc/sysctl.d/11-nf-conntrack.conf <<'EOF'
net.netfilter.nf_conntrack_max=8192
EOF

# one-shot UCI tuning, self-deletes after first boot
cat > files/etc/uci-defaults/99-rm1800-tuning <<'EOF'
#!/bin/sh
uci set dhcp.@dnsmasq[0].cachesize='1000'
uci commit dhcp
exit 0
EOF

# verify it landed (fail loud if not — the saga lesson)
test -f files/etc/uci-defaults/99-rm1800-tuning || { echo "::error::tuning uci-defaults missing"; exit 1; }
ls -la files/etc/uci-defaults/ files/etc/sysctl.d/

echo "=== bake VM watermark tuning (sysctl.d) ==="
mkdir -p files/etc/sysctl.d
cat > files/etc/sysctl.d/12-rm1800-vm.conf <<'EOF'
vm.min_free_kbytes=4096
vm.watermark_boost_factor=0
EOF
test -s files/etc/sysctl.d/12-rm1800-vm.conf || { echo "::error::vm sysctl.d missing"; exit 1; }

PBUF_INIT=$(find package feeds -path '*qca-nss-pbuf*' -name '*.init' 2>/dev/null | head -1)
git checkout -- "$PBUF_INIT" 2>/dev/null || true
if [ $PBUF_SHRINK = 1 ]; then
  echo "=== NSS pbuf tier for ~148MB MemTotal ==="
  test -n "$PBUF_INIT" || { echo "::error::qca-nss-pbuf init not found"; exit 1; }
  echo "Patching: $PBUF_INIT"
  # sed -i -e 's/n2h_wifi_pool_buf=8192/n2h_wifi_pool_buf=2048/' \
  #       -e 's/n2h_high_water_core0=16384/n2h_high_water_core0=4096/' \
  #       -e 's/extra_pbuf_core0=4000000/extra_pbuf_core0=1000000/' "$PBUF_INIT"
  sed -i -e 's/n2h_wifi_pool_buf=8192/n2h_wifi_pool_buf=4096/' \
       -e 's/n2h_high_water_core0=16384/n2h_high_water_core0=8192/' \
       "$PBUF_INIT"
  # leaving extra_pbuf_core0=4000000 at stock

  grep -nE 'n2h_wifi_pool_buf=|n2h_high_water_core0=|extra_pbuf_core0=' "$PBUF_INIT"
fi


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
No-NSS=${NONSS}
CMA Mainstream=${CMA_MAINSTREAM}
CMA=${CMA_SIZE}M
DTS_Mode=${DTS_MODE}
Mem profile=${ATH11K_MEM_PROFILE}M
Mon-off=${MON_OFF}
No-Usb=${NO_USB}
Rings shrunk=${RINGS_SHRINK}
Pbuf shrink=${PBUF_SHRINK}
notes="2.12 ddwrt firmware; VmMinFree: 4M; Dtsi 256M; mdns"
EOF
cat files/etc/build-id

echo "=== mutate.sh done ==="
