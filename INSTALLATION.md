# Installation

This gets you a booting **Kali Linux ARM64** on the r8q, reachable from your PC
over the USB cable (SSH + internet). Read [`PREREQUISITES.md`](PREREQUISITES.md)
first — **this wipes `userdata`.**

Throughout: `$KSRC` = your mainline kernel source, `$OUT` = its build dir
(`O=`), `$MUSIL` = your Mu-Silicium checkout. `KV` is the kernel release (e.g.
`7.1.2`).

---

## 1. Build the kernel (Image + DTB)

Install the host packages in [`PREREQUISITES.md`](PREREQUISITES.md) and provide
a **static AArch64 BusyBox** for the embedded initramfs. By default the build
script shallow-clones `ben443/Linux-mainline-nethunter-pro` (`kali/master`) into
`dl/`; this kernel branch contains the r8q device-tree files tracked here. To
use a kernel tree already on disk, pass its path as `KSRC`. The script stages
this repository's device-tree files, applies its patches, and configures the
initramfs and forced kernel command line:

```bash
# BUSYBOX: statically linked AArch64 BusyBox
BUSYBOX=/path/to/busybox ./scripts/build.sh
# Or use an existing Linux source tree instead of the default kernel fork:
KSRC=/path/to/linux BUSYBOX=/path/to/busybox ./scripts/build.sh
```

The kernel-only output is in `out/kernel/`. To also build the Mu-Silicium UEFI
image, set `MUSIL` to its checkout:

```bash
BUSYBOX=/path/to/busybox MUSIL=/path/to/Mu-Silicium ./scripts/build.sh
```

The linked NetHunter Pro repository builds an Android `boot.img` for `r8q` with
Samsung boot-image offsets. This project instead boots Mu-Silicium UEFI and loads
`BOOTAA64.EFI` from the ESP, so those boot-image offsets and packaging steps do
not apply here; this build compiles the `sm8250-samsung-r8q.dtb` target and embeds
it in Mu-Silicium.

Before building UEFI, enable the "Device Tree" FREEFORM block in
`$MUSIL/Platforms/Samsung/r8qPkg/r8q.fdf`. The build script embeds the DTB in
Mu-Silicium; it does not flash the phone or format partitions.

Keep `simpledrm` enabled. Outputs: `out/kernel/arch/arm64/boot/Image` and
`out/kernel/arch/arm64/boot/dts/qcom/sm8250-samsung-r8q.dtb`.

## 2. Embed the DTB and build UEFI

The DTB lives **inside the firmware** (Mu-Silicium exposes it to the kernel via
`DtPlatformDxe`). Enable the "Device Tree" FREEFORM block in
`$MUSIL/Platforms/Samsung/r8qPkg/r8q.fdf`, then:

```bash
MUSIL=$MUSIL DTB=$OUT/arch/arm64/boot/dts/qcom/sm8250-samsung-r8q.dtb ./scripts/build-uefi.sh
# -> $MUSIL/Mu-r8q-0.img
```

## Automated build artifacts

The GitHub Actions **Build r8q images** workflow builds the kernel and Mu-Silicium
UEFI image, then uploads a downloadable `r8q-linux-<kernel-release>` artifact.
Download the artifact from the workflow run and extract its `.tar.gz` bundle to get:

- `Mu-r8q-0.img` — UEFI image to flash to `BOOT`.
- `EFI/BOOT/BOOTAA64.EFI` — kernel `Image` to deploy to the ESP.
- `dtb/sm8250-samsung-r8q.dtb` — the DTB embedded in the UEFI image.
- `modules/lib/modules/<kernel-release>/` — installable kernel modules.
- `SHA256SUMS` — checksums for the packaged files.

This is a build-output bundle, not a prebuilt Kali userdata image; installing Kali
still uses the device-specific, destructive steps in section 6. The current Kali
setup starts from the minimal NetHunter rootfs and does not install Phosh or
`kali-mobile-themes`. The documented desktop setup is KDE Plasma Mobile, with
GNOME and sway as alternatives.

## 3. Flash UEFI to BOOT

Put the phone in **download mode** (power off; VolUp+VolDown; plug USB):

```bash
./scripts/flash.sh $MUSIL/Mu-r8q-0.img       # heimdall flash --BOOT ...; it reboots
```

The phone now boots Mu-Silicium UEFI on every power-on.

## 4. Prepare the ESP (once)

Boot the phone into Mu-Silicium **mass-storage** mode. The ESP is the phone's
`cache` partition — reformat it vfat once (UFS logical block is 4096):

```bash
ESP=$(lsblk -o NAME,PARTLABEL -rn | awk '$2=="cache"{print "/dev/"$1}')
sudo mkfs.vfat -F 32 -S 4096 -n R8QESP "$ESP"
```

## 5. Deploy the kernel Image to the ESP

Still in mass-storage mode:

```bash
./scripts/deploy-esp.sh $OUT/arch/arm64/boot/Image   # -> ESP:/EFI/BOOT/BOOTAA64.EFI
```

## 6. Install Kali onto userdata

Still in mass-storage mode (this **formats userdata**):

```bash
KV=7.1.2 OUT=$OUT KSRC=$KSRC ./scripts/install-kali.sh
```

It extracts the minimal Kali NetHunter ARM64 rootfs, **moves the kernel module tree aside** (cold-plugging
the full tree hard-resets the SoC — see the note in the script), lays down our
[`rootfs/`](rootfs/) overlay, enables `ssh` + `systemd-networkd` +
`r8q-usb-gadget`, sets root autologin on `tty1`, root password `root`, and
enables root SSH password login for initial setup.

## 7. Boot

Exit mass storage and let the phone boot. You should see the panel show the
switch-root message, then systemd, then a root shell (autologin). On the PC an
NCM network device appears:

```bash
DEV=<the new cdc_ncm netdev>
sudo ip addr add 172.16.42.14/24 dev "$DEV"; sudo ip link set "$DEV" up
ssh root@172.16.42.1            # password: root
```

## 8. USB tethering (internet + apt)

Share the PC's internet to the phone (host NAT is runtime — re-run after a PC
reboot):

```bash
./scripts/host-tether.sh        # enables ip_forward + MASQUERADE for 172.16.42.0/24
```

The phone already has `Gateway=172.16.42.14` + DNS baked into
`rootfs/etc/systemd/network/20-usb0.network`, so once the host NAT is up:

```bash
ssh root@172.16.42.1 'ping -c2 kali.org'
# Refresh Kali's package index and bring the rolling system up to date first:
ssh root@172.16.42.1 'apt update && apt full-upgrade'
```

## 9. GPU acceleration (Adreno 650) + sway

Prereq: the kernel was built **with the [`patches/`](patches/) applied**
(`build_kernel.sh` does this) and its modules are installed on the rootfs —
at minimum `msm.ko` and its dependencies under `/lib/modules/$KV/`.

**a) Userspace + generic firmware** (on the phone, over SSH):

```bash
apt install mesa-vulkan-drivers firmware-qcom-soc firmware-atheros sway foot seatd
systemctl enable --now seatd
```

That provides `/lib/firmware/qcom/a650_sqe.fw` and `a650_gmu.bin`.

**b) The zap shader — from YOUR device's stock firmware.** Samsung's TrustZone
only authenticates a **Samsung-signed** zap; the generic
`qcom/sm8250/a650_zap.mbn` from linux-firmware is rejected (`-22`) and the GPU
then silently drops every render write. Get the stock firmware for your model
(e.g. the AP tarball from samfw/frija), pull `a650_zap.mdt` + `a650_zap.b00/.b01/.b02`
out of the `vendor` image (`/vendor/firmware/`), and install them as:

```
/lib/firmware/qcom/sm8250/a650_zap.mbn    <- the stock a650_zap.mdt, renamed
/lib/firmware/qcom/sm8250/a650_zap.b00
/lib/firmware/qcom/sm8250/a650_zap.b01
/lib/firmware/qcom/sm8250/a650_zap.b02
```

**c) Module options + post-boot load.** The [`rootfs/`](rootfs/) overlay ships
these (already in place if you re-ran the overlay):

- `etc/modprobe.d/r8q-gpu.conf` — `blacklist msm` **plus**
  `options msm separate_gpu_kms=1 r8q_zap_dyn=1 r8q_zap_secvid=0`.
  `r8q_zap_dyn=1` is **required**: it loads the zap into dynamically allocated
  RAM; pointing it at the DT carveout makes Samsung's TZ **hard-reset the SoC**.
- `etc/systemd/system/r8q-gpu.service` — loads `msm` after `multi-user.target`
  (never let udev coldplug it). `systemctl enable r8q-gpu.service`.
- `root/.bash_profile` — tty1 autologin waits for `renderD128`, then starts
  **sway** with the vulkan (turnip) renderer: render node `renderD128`,
  scanout on simpledrm `card0`.

**d) Verify** (after a reboot):

```bash
ssh root@172.16.42.1 'ls /dev/dri; dmesg | grep -i zap'
# want: renderD128 present, "r8q: zap region dma_alloc'd at ..." and NO "zap auth failed"
```

Sway should be on the panel. Rules of the road: **never `rmmod msm`** (GMU/IOMMU
teardown wedges the kernel — load once per boot), and never write the SECVID
registers from the kernel (the hypervisor traps them; that is what
`r8q_zap_secvid=0` keeps disabled).

## 10. Wi-Fi (QCA6390 over PCIe)

No kernel config changes are needed — ATH11K(+PCI), MHI, QRTR, `PCIE_QCOM`,
`PCI_PWRCTRL_PWRSEQ` and `POWER_SEQUENCING_QCOM_WCN` are all in `arm64`
defconfig. The DT nodes are in [`dts/`](dts/) and the firmware comes from
`linux-firmware`.

**a) Modules and firmware on the phone.** `make modules_install` must have put
these under `/lib/modules/$KV/`, and one of them is easy to miss:

```bash
ssh root@172.16.42.1 'ls /lib/firmware/ath11k/QCA6390/hw2.0/'   # amss.bin board-2.bin m3.bin
ssh root@172.16.42.1 'modinfo qrtr-mhi | head -2'               # MUST be present
```

If `qrtr-mhi.ko` is missing, install it and re-run `depmod -a`. Without it
nothing binds to the MHI `IPCR` channel, QMI never starts, and ath11k stops
dead at `Wait for device to enter SBL or Mission mode` with no further output —
which looks like a firmware failure but is not one.

**b) Overlay + service.** The [`rootfs/`](rootfs/) overlay ships:

- `etc/modprobe.d/r8q-wifi-blacklist.conf` — keeps udev from coldplugging the
  Wi-Fi stack at ~9 s, which races the touch/battery geni bring-up (SE0 i2c
  timeouts + MAX77705 IRQ storms).
- `etc/systemd/system/r8q-wifi.service` — loads it deliberately instead, in
  order: `phy-qcom-qmp-pcie` (the PCIe **phy is a module**; without it
  `1c00000.pcie` silently defers) → `pwrseq-qcom-wcn` → `pci-pwrctrl-pwrseq` →
  wait for the endpoint → `qrtr-mhi` → `ath11k_pci`.
- `etc/NetworkManager/conf.d/10-r8q.conf` — see (c).

```bash
ssh root@172.16.42.1 'systemctl enable --now r8q-wifi.service'
ssh root@172.16.42.1 'dmesg | grep ath11k'   # want: fw_version ..., "renamed from wlan0"
```

**c) NetworkManager, so you can connect from the GNOME UI.** Install it *before*
starting it, and put the config in place first — the config is what keeps NM off
`usb0`, and `usb0` is the SSH connection you are typing over:

```bash
apt install network-manager wireless-regdb
install -Dm644 rootfs/etc/NetworkManager/conf.d/10-r8q.conf \
               /etc/NetworkManager/conf.d/10-r8q.conf   # usb0 unmanaged, dns=none
systemctl enable --now NetworkManager
systemctl disable NetworkManager-wait-online.service    # else it stalls boot
nmcli device status      # want: wlp1s0 managed, usb0 "unmanaged"
```

Two gotchas:

- Keep Kali's rolling packages in sync: run `apt update && apt full-upgrade`
  before installing or upgrading individual packages.
- Do package installs over a transient link with
  `systemd-run --unit=install --collect apt install ...` so an SSH drop cannot
  abort the transaction half-way.

Then join a network from **Settings → Wi-Fi** on the phone itself, or over SSH:

```bash
nmcli device wifi list
nmcli device wifi connect 'YOUR-SSID' password 'YOUR-PASSPHRASE'
```

NM stores the connection in `/etc/NetworkManager/system-connections/`, so it
reconnects on its own after a reboot.

**Debugging note.** If MHI ever stalls again, build `mhi.ko` with
`CONFIG_MHI_BUS_DEBUG=y` and read `/sys/kernel/debug/mhi/*/regdump`. It prints
`BHI_EXECENV` / `BHI_STATUS` / `BHI_ERRCODE` / `BHI_ERRDBG1-3` — PBL's own
verdict on the firmware. `BHI_EXECENV: 0x2` means the chip is already in mission
mode and the fault is above MHI, not in the firmware.

---

## 11. The CPU-wedge workaround (do this before running any desktop)

Without this the phone stops dead under load. It is **not** a display or GPU
fault: **a core enters idle and never comes back out.** RCU reports it plainly,
printing that CPU with an **even** dynticks counter
(`idle=…/1/0x4000000000000000`), i.e. it believes the core is idle, and the same
frozen values are still there in every stall report minutes later. Everything
that needs a global IPI then blocks behind it — which is why the visible
backtraces are usually innocent victims in `kick_all_cpus_sync ← __text_poke`.

The tell is unmistakable once you know it: **the kernel keeps answering ICMP
while userspace stops entirely** — `ping` stays at ~2 ms while `sshd` cannot even
emit its version banner (`Connection timed out during banner exchange`). It
usually degrades to a full hang after that; recovery is the physical VolUp+Power
combo either way.

**a) Disable the deep idle state on every core.** This is a mitigation, not a
cure: cores have been lost with it applied. It does make the failure much rarer,
because power collapse fails far more often than plain WFI does.

```bash
install -Dm644 rootfs/etc/tmpfiles.d/50-r8q-cpuidle.conf \
               /etc/tmpfiles.d/50-r8q-cpuidle.conf
systemd-tmpfiles --create /etc/tmpfiles.d/50-r8q-cpuidle.conf

# verify: no core power-collapses any more
for c in 0 1 2 3 4 5 6 7; do echo -n "cpu$c=$(cat /sys/devices/system/cpu/cpu$c/cpuidle/state1/disable) "; done; echo
#   want: all 1
```

**b) For heavy work, stop the cores idling at all.** What actually correlates
with the wedge is idle-entry rate, not utilisation: a compile idles the cores
~500×/s and kills the phone within a minute, while an 8-core spin loop at 85 °C
runs indefinitely. A `SCHED_IDLE` spinner pinned to each core keeps the idle loop
from ever being entered and costs real work nothing, because SCHED_IDLE only runs
when a CPU would otherwise have had nothing to do.

```bash
install -Dm755 rootfs/usr/local/sbin/r8q-noidle.sh /usr/local/sbin/r8q-noidle.sh
install -Dm644 rootfs/etc/systemd/system/r8q-noidle.service \
               /etc/systemd/system/r8q-noidle.service
systemctl daemon-reload

# around anything heavy (a Rust build will not survive without it):
systemctl start r8q-noidle
cd ~/paru && makepkg -si
systemctl stop r8q-noidle
```

It is deliberately not enabled at boot: no core ever sleeps while it runs. The
in-kernel equivalent, if you would rather pay that permanently, is `nohlt` on the
cmdline — that needs an `Image` rebuild, since `CONFIG_CMDLINE_FORCE=y`.

## 12. KDE Plasma Mobile

```bash
systemd-run --unit=install --collect apt install plasma-mobile plasma-settings kscreen sddm
```

**a) Stop PowerDevil from suspending — do this BEFORE the first login.** Suspend
is a hard reset on this device (see the sleep-target masking earlier), and
PowerDevil will happily idle-suspend into it.

```bash
for f in powerdevilrc powermanagementprofilesrc kscreenlockerrc; do
  install -Dm644 rootfs/etc/xdg/$f /etc/xdg/$f
done
```

`powermanagementprofilesrc` deliberately omits the `[*][SuspendSession]` group in
every profile, `powerdevilrc` sets `BatteryCriticalAction=0` (the fuel gauge reads
critical while the pack is fine), and `kscreenlockerrc` disables auto-locking —
with autologin and no hardware keyboard, a lock screen is an easy way to lock
yourself out of the panel. These live in `/etc/xdg` safely:
`plasma-mobile-envmanager` only generates `~/.config/plasma-mobile/{kwinrc,
kdeglobals,ksmserverrc}` and never touches them.

**b) sddm.** There is no Xorg on this device at all, and sddm still defaults its
Wayland greeter to weston, so both settings are required:

```bash
install -Dm644 rootfs/etc/sddm.conf.d/10-r8q.conf /etc/sddm.conf.d/10-r8q.conf
install -Dm644 rootfs/etc/systemd/system/sddm.service.d/r8q-after-gpu.conf \
               /etc/systemd/system/sddm.service.d/r8q-after-gpu.conf
systemctl daemon-reload
systemctl disable gdm && systemctl enable sddm
```

The `r8q-after-gpu.conf` drop-in is load-bearing: KWin picks its render device
once at startup, so if sddm beats `r8q-gpu.service` the session silently runs on
llvmpipe.

**c) Verify it got the GPU.**

```bash
ls -l /proc/$(pgrep -x kwin_wayland)/fd | grep -o '/dev/dri/[a-zA-Z0-9]*' | sort | uniq -c
#   want: 3 /dev/dri/card0   and   8 /dev/dri/renderD128
```

KWin needs no GPU configuration of its own — do **not** port GNOME's
`mutter-device-preferred-primary` udev tag or `MUTTER_DEBUG_MULTI_GPU_FORCE_COPY_MODE`
across. It has a real split display/render-device concept, treats every
`DRM_BUS_PLATFORM` node as compatible and prefers the non-software renderer, and
both of ours are platform-bus. If it ever guesses wrong, force it with
`KWIN_RENDER_NODES=/dev/dri/renderD128`.

Scale is automatic — KWin's phone-panel DPI heuristic yields **2.7** (logical
400x889) for this display, but only because `patches/0006` makes the connector
DSI and the DT carries `width-mm`/`height-mm`. Check with `kscreen-doctor -o`,
which needs `WAYLAND_DISPLAY=wayland-0` in addition to the usual
`XDG_RUNTIME_DIR` / `DBUS_SESSION_BUS_ADDRESS`.

GNOME stays installed; revert with `systemctl disable sddm && systemctl enable gdm`.

## Protect the Samsung zap shader from package upgrades

The package owning `/usr/lib/firmware/qcom/sm8250/a650_zap.mbn` may overwrite
your Samsung-signed blob during an upgrade, after which the GPU hangs on its first
submit. Before installing the local blob, divert the package-owned path once (use
`dpkg-query -S` to confirm the exact path in your Kali rootfs):

```bash
dpkg-divert --local --rename --add /usr/lib/firmware/qcom/sm8250/a650_zap.mbn
```

The package's version is kept as `.distrib`; then install the Samsung-signed blob
at the original path. Verify at any time with
`md5sum /usr/lib/firmware/qcom/sm8250/a650_zap.mbn` against your saved copy.

**`systemctl reboot` does not come back.** Mu-Silicium lives on the `RECOVERY`
  partition, so returning to Linux always needs the physical
  **VolUp+Power with USB connected** combo.
