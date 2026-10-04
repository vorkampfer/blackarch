#!/usr/bin/env bash
# inspect_eee.sh — inspect Energy Efficient Ethernet, turn it off, keep it off.
# PARROT OS VERSION 1.0.0 2026-10-04
# EEE (IEEE 802.3az) is a PHY power-save, not a kernel module. You cannot
# `blacklist eee`, and blacklisting r8169/r8152 unloads the NIC. On Realtek
# those idle "naps" often flap the link or take the card down. ethtool
# --set-eee is live-only; some boxes (the Arch failure mode) re-enable EEE
# a few seconds later.
#
# Closest thing to a blacklist: /etc/modprobe.d/blacklist-eee.conf
# (install hooks + eee=0 only where modinfo lists that param). If EEE still
# runs, --disable-eee, --watch, or --lock-down add udev / NM / systemd.
#
#   ./inspect_eee.sh                         # --status (default)
#   ./inspect_eee.sh --blacklist             # modprobe rule + disable now
#   ./inspect_eee.sh --disable-eee           # live kill only
#   ./inspect_eee.sh --lock-down             # disable now + every persist hook
#   ./inspect_eee.sh --watch                 # re-kill if EEE comes back
#   ./inspect_eee.sh --help

function ctrl_c() {
	echo -e "\n\n${redColour}[+] Exiting EEE inspector...${endColour}\n"
	exit 130
}
trap ctrl_c SIGINT

# -u: unset variables are errors; pipefail: a failing command fails the whole pipe
set -uo pipefail

greenColour="\e[0;32m\033[1m"
endColour="\033[0m\e[0m"
redColour="\e[0;31m\033[1m"
blueColour="\e[0;34m\033[1m"
yellowColour="\e[0;33m\033[1m"
purpleColour="\e[0;35m\033[1m"
cyanColour="\e[0;36m\033[1m"
grayColour="\e[0;37m\033[1m"

HELPER="/usr/local/sbin/eee-apply-off"
MODPROBE_CONF="/etc/modprobe.d/blacklist-eee.conf"
# leftover name from an earlier version; --blacklist removes it if present
MODPROBE_CONF_OLD="/etc/modprobe.d/disable-eee.conf"
UDEV_RULE="/etc/udev/rules.d/99-disable-eee.rules"
NM_DISPATCH="/etc/NetworkManager/dispatcher.d/pre-up.d/99-disable-eee"
SYSTEMD_ONCE="/etc/systemd/system/disable-eee.service"
SYSTEMD_WATCH="/etc/systemd/system/eee-watchdog.service"
WATCH_INTERVAL_DEFAULT=3

ACTION=""
DRY_RUN=0
WATCH_INTERVAL="$WATCH_INTERVAL_DEFAULT"
declare -a IFACE_FILTER=()

# resolve_ethtool: Debian/Parrot keep it in /usr/sbin; Arch often uses /usr/bin
resolve_ethtool() {
	local c
	for c in ethtool /usr/sbin/ethtool /sbin/ethtool /usr/bin/ethtool; do
		if command -v "$c" >/dev/null 2>&1; then
			command -v "$c"
			return 0
		fi
		if [[ -x "$c" ]]; then
			printf '%s\n' "$c"
			return 0
		fi
	done
	return 1
}

ETHTOOL=""
if ! ETHTOOL=$(resolve_ethtool); then
	ETHTOOL=""
fi

usage() {
	cat <<EOF
Usage: $0 [flags]

Inspect / kill Energy Efficient Ethernet (IEEE 802.3az). Default is --status.

EEE is not a kernel module. \`blacklist eee\` does nothing, and blacklisting
r8169/r8152 unloads the NIC. --blacklist writes ${MODPROBE_CONF}
(install hooks + any real eee=0 params) and disables live EEE.

Report
  --status, -s, --doctor, --report
                             Live EEE report, persistence inventory, verdict
  --explain, --what-is-eee   What EEE is and why it eats Realtek NICs
  --watch                    Loop: if EEE comes back, kill it again (Ctrl+C)
  --interval N               Seconds between --watch polls (default ${WATCH_INTERVAL_DEFAULT})

Act now (needs root)
  --blacklist                Preferred: write ${MODPROBE_CONF} + disable now
  --disable-eee, --kill, -d, --off
                             ethtool --set-eee … eee off (live only)
  --iface IFACE              Limit to one NIC (repeatable). Default: every wired NIC

Persist (needs root; each flag also installs ${HELPER})
  --install-modprobe-rule    ${MODPROBE_CONF} only (no live disable)
  --install-udev-rule        Fire the helper when a net device appears
  --install-systemd          oneshot unit at boot
  --install-nm               NetworkManager pre-up + ethtool.eee-enabled=off
  --install-watchdog         systemd service that re-kills EEE if it respawns
  --install-all, --lock-down, --lockdown, --never-again
                             Disable now + every persist hook (if EEE still runs)
  --uninstall                Remove helper, hooks, and units

Other
  --dry-run, -n              Print what would run; write nothing
  --help, -h                 This help

Exit codes for --status / --disable-eee / --blacklist:
  0  EEE is disabled (or no EEE-capable wired NIC)
  1  EEE is still enabled on at least one NIC
  2  Missing ethtool / permission / usage error

The Arch failure mode: EEE ignored ethtool, came back every few seconds, and
took the ethernet card down. Start with --blacklist. If --status still shows
ENABLED, use --lock-down and --watch.
EOF
}

# ensure_sudo: confirm we can elevate; prompt once if needed, else exit
ensure_sudo() {
	if [[ "$DRY_RUN" -eq 1 ]]; then
		return 0
	fi
	if [[ "${EUID}" -eq 0 ]]; then
		return 0
	fi
	if ! command -v sudo >/dev/null 2>&1; then
		echo -e "${redColour}Need root (or sudo) for this action.${endColour}" >&2
		exit 2
	fi
	if ! sudo -v; then
		echo -e "${redColour}sudo failed.${endColour}" >&2
		exit 2
	fi
}

# run_root: sudo unless already root; in dry-run only print the command
run_root() {
	if [[ "$DRY_RUN" -eq 1 ]]; then
		echo -e "${yellowColour}[dry-run]${endColour} $*"
		return 0
	fi
	if [[ "${EUID}" -eq 0 ]]; then
		"$@"
	else
		sudo "$@"
	fi
}

# write_root_file DEST MODE: read stdin and write as root (or preview)
write_root_file() {
	local dest="$1"
	local mode="$2"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		echo -e "${yellowColour}[dry-run] would write ${dest} (mode ${mode})${endColour}"
		sed 's/^/  /'
		return 0
	fi
	ensure_sudo
	# tee as root so we do not depend on a root shell for the redirect
	if [[ "${EUID}" -eq 0 ]]; then
		cat >"$dest"
		chmod "$mode" "$dest"
	else
		sudo tee "$dest" >/dev/null
		sudo chmod "$mode" "$dest"
	fi
}

# is_wired_iface: ethernet-looking NICs only (skip lo, wifi, bridges, tunnels)
is_wired_iface() {
	local n="$1"
	local ntype
	[[ -d "/sys/class/net/${n}" ]] || return 1
	[[ "$n" == "lo" ]] && return 1
	[[ -d "/sys/class/net/${n}/wireless" ]] && return 1
	[[ -f "/sys/class/net/${n}/type" ]] || return 1
	ntype=$(<"/sys/class/net/${n}/type")
	[[ "$ntype" == "1" ]] || return 1
	case "$n" in
		wlan*|wlx*|wlp*|docker*|veth*|br-*|virbr*|tun*|tap*|wg*|tailscale*|zt*|nm-*)
			return 1
			;;
	esac
	return 0
}

# list_wired_ifaces: honor --iface filters if the user passed any
list_wired_ifaces() {
	local n
	if [[ "${#IFACE_FILTER[@]}" -gt 0 ]]; then
		for n in "${IFACE_FILTER[@]}"; do
			if [[ ! -d "/sys/class/net/${n}" ]]; then
				echo -e "${redColour}No such interface: ${n}${endColour}" >&2
				continue
			fi
			printf '%s\n' "$n"
		done
		return 0
	fi
	for n in /sys/class/net/*; do
		n="${n##*/}"
		is_wired_iface "$n" || continue
		printf '%s\n' "$n"
	done
}

# iface_driver / iface_bus / iface_fw: ethtool -i fields (empty if unavailable)
iface_driver() {
	"$ETHTOOL" -i "$1" 2>/dev/null | awk -F': ' '/^driver:/{print $2; exit}'
}
iface_bus() {
	"$ETHTOOL" -i "$1" 2>/dev/null | awk -F': ' '/^bus-info:/{print $2; exit}'
}
iface_fw() {
	"$ETHTOOL" -i "$1" 2>/dev/null | awk -F': ' '/^firmware-version:/{print $2; exit}'
}

# iface_operstate: kernel operstate (up/down/dormant/unknown) plus carrier
# $(<file) plus extra redirects can parse as an empty command — use cat
iface_operstate() {
	local n="$1"
	local state carrier
	state=$(cat "/sys/class/net/${n}/operstate" 2>/dev/null || echo '?')
	if [[ -f "/sys/class/net/${n}/carrier" ]]; then
		carrier=$(cat "/sys/class/net/${n}/carrier" 2>/dev/null || echo '?')
		if [[ "$carrier" == "1" ]]; then
			printf '%s (carrier)' "$state"
		else
			printf '%s (no carrier)' "$state"
		fi
	else
		printf '%s' "$state"
	fi
}

# iface_speed: ethtool Speed line, or sysfs speed as a fallback
iface_speed() {
	local n="$1"
	local spd
	spd=$("$ETHTOOL" "$n" 2>/dev/null | awk -F': ' '/Speed:/{print $2; exit}')
	if [[ -z "$spd" || "$spd" == "Unknown!" ]]; then
		if [[ -f "/sys/class/net/${n}/speed" ]]; then
			spd=$(<"/sys/class/net/${n}/speed" 2>/dev/null || true)
			[[ -n "$spd" && "$spd" != "-1" ]] && spd="${spd}Mb/s"
		fi
	fi
	printf '%s' "${spd:-unknown}"
}

# eee_raw: full --show-eee blob (or the error text)
eee_raw() {
	"$ETHTOOL" --show-eee "$1" 2>&1 || true
}

# eee_state: enabled | disabled | unsupported | unknown
eee_state() {
	local raw
	raw=$(eee_raw "$1")
	if grep -qiE 'not supported|Operation not supported' <<<"$raw"; then
		printf 'unsupported'
		return 0
	fi
	if grep -qiE 'No such device|no device matches' <<<"$raw"; then
		printf 'missing'
		return 0
	fi
	if grep -qiE 'EEE status:[[:space:]]*disabled' <<<"$raw"; then
		printf 'disabled'
		return 0
	fi
	if grep -qiE 'EEE status:[[:space:]]*enabled' <<<"$raw"; then
		printf 'enabled'
		return 0
	fi
	printf 'unknown'
}

# eee_active_note: "active" (in LPI now) vs "inactive" (armed, not napping)
eee_active_note() {
	local raw
	raw=$(eee_raw "$1")
	if grep -qiE 'enabled[[:space:]]*-[[:space:]]*active' <<<"$raw"; then
		printf 'active'
	elif grep -qiE 'enabled[[:space:]]*-[[:space:]]*inactive' <<<"$raw"; then
		printf 'inactive'
	else
		printf ''
	fi
}

# driver_risk: Realtek in-tree drivers are the usual EEE-kills-the-NIC suspects
driver_risk() {
	case "$1" in
		r8169|r8152|r8168)
			printf 'HIGH'
			;;
		igb|e1000e|igc|tg3)
			printf 'MED'
			;;
		*)
			printf 'LOW'
			;;
	esac
}

# persist_present: 0 if that hook file exists
persist_present() {
	[[ -e "$1" ]]
}

# unit_active: systemd is-active, or "absent"
unit_active() {
	local u="$1"
	if ! command -v systemctl >/dev/null 2>&1; then
		printf 'n/a'
		return 0
	fi
	if [[ ! -e "/etc/systemd/system/${u}" && ! -e "/usr/lib/systemd/system/${u}" ]]; then
		printf 'absent'
		return 0
	fi
	systemctl is-active "$u" 2>/dev/null || printf 'inactive'
}

need_ethtool() {
	if [[ -z "$ETHTOOL" ]]; then
		echo -e "${redColour}ethtool is not installed.${endColour}" >&2
		echo -e "${yellowColour}Arch: sudo pacman -S ethtool${endColour}" >&2
		echo -e "${yellowColour}Parrot/Debian: sudo apt install ethtool${endColour}" >&2
		exit 2
	fi
}

# helper_body: tiny POSIX helper installed to /usr/local/sbin for udev/systemd/modprobe
helper_body() {
	cat <<'EOS'
#!/bin/sh
# eee-apply-off — disable EEE on wired NICs. Called from udev, systemd, modprobe.
# Installed by inspect_eee.sh. Do not add a watch loop to udev RUN+ (udev wants fast).

ETHTOOL=""
for c in /usr/sbin/ethtool /sbin/ethtool /usr/bin/ethtool; do
	if [ -x "$c" ]; then
		ETHTOOL="$c"
		break
	fi
done
[ -n "$ETHTOOL" ] || exit 0

WATCH=0
INTERVAL=3
TARGET=""

while [ $# -gt 0 ]; do
	case "$1" in
		--watch) WATCH=1 ;;
		--interval)
			INTERVAL="$2"
			shift
			;;
		-*) ;;
		*) TARGET="$1" ;;
	esac
	shift
done

is_wired() {
	n="$1"
	[ -d "/sys/class/net/$n" ] || return 1
	[ "$n" = "lo" ] && return 1
	[ -d "/sys/class/net/$n/wireless" ] && return 1
	[ -f "/sys/class/net/$n/type" ] || return 1
	[ "$(cat "/sys/class/net/$n/type")" = "1" ] || return 1
	case "$n" in
		wlan*|wlx*|wlp*|docker*|veth*|br-*|virbr*|tun*|tap*|wg*|tailscale*|zt*)
			return 1
			;;
	esac
	return 0
}

disable_one() {
	iface="$1"
	out=$($ETHTOOL --show-eee "$iface" 2>&1) || return 0
	echo "$out" | grep -qiE 'EEE status:[[:space:]]*enabled' || return 0
	if ! $ETHTOOL --set-eee "$iface" eee off tx-lpi off >/dev/null 2>&1; then
		$ETHTOOL --set-eee "$iface" eee off >/dev/null 2>&1 || return 1
	fi
	logger -t eee-apply-off "EEE was enabled on $iface — disabled it"
}

apply() {
	if [ -n "$TARGET" ]; then
		disable_one "$TARGET"
		return
	fi
	for path in /sys/class/net/*; do
		n=${path##*/}
		is_wired "$n" || continue
		disable_one "$n"
	done
}

if [ "$WATCH" -eq 1 ]; then
	while :; do
		apply
		sleep "$INTERVAL"
	done
else
	apply
fi
EOS
}

install_helper() {
	echo -e "${blueColour}Installing helper ${HELPER}${endColour}"
	helper_body | write_root_file "$HELPER" 755
}

# emit_eee_options: only write options FOO=0 when modinfo actually lists that parm
# Unknown module params can refuse to load the NIC driver on strict kernels.
emit_eee_options() {
	local mod line parm
	local found=0
	for mod in r8168 r8169 r8152 igb e1000e igc tg3 atlantic ixgbe i40e; do
		while IFS= read -r line; do
			parm="${line%%:*}"
			parm="${parm%%[[:space:]]*}"
			[[ "$parm" =~ ^[Ee][Ee][Ee](_enable)?$ ]] || continue
			echo "options ${mod} ${parm}=0"
			found=1
		done < <(modinfo -p "$mod" 2>/dev/null || true)
	done
	if [[ "$found" -eq 0 ]]; then
		echo "# No loaded/available NIC module advertised an EEE parameter (typical for r8169/r8152)."
		echo "# The install hooks above are the blacklist — they ethtool-kill EEE as the driver loads."
	fi
	# r8168 out-of-tree driver is often not installed; this line is inert until that module exists
	echo "options r8168 eee=0"
}

# install_modprobe_rule: closest thing to "blacklist EEE" — EEE is not a module
install_modprobe_rule() {
	install_helper
	if persist_present "$MODPROBE_CONF_OLD"; then
		echo -e "${yellowColour}Replacing older ${MODPROBE_CONF_OLD}${endColour}"
		run_root rm -f "$MODPROBE_CONF_OLD"
	fi
	echo -e "${blueColour}Writing ${MODPROBE_CONF}${endColour}"
	{
		cat <<EOF
# blacklist-eee.conf
# There is no "eee" kernel module. Do NOT blacklist r8169 or r8152 — that unloads the NIC.
# r8169/r8152 have no eee=0 module parameter. The install lines wrap the real
# modprobe (--ignore-install avoids recursion) and run eee-apply-off after load.
# \$CMDLINE_OPTS keeps any module options from the kernel command line.

install r8169 /sbin/modprobe --ignore-install r8169 \$CMDLINE_OPTS && /bin/sleep 1 && ${HELPER}
install r8152 /sbin/modprobe --ignore-install r8152 \$CMDLINE_OPTS && /bin/sleep 1 && ${HELPER}
install r8168 /sbin/modprobe --ignore-install r8168 \$CMDLINE_OPTS && /bin/sleep 1 && ${HELPER}
install igb /sbin/modprobe --ignore-install igb \$CMDLINE_OPTS && /bin/sleep 1 && ${HELPER}
install e1000e /sbin/modprobe --ignore-install e1000e \$CMDLINE_OPTS && /bin/sleep 1 && ${HELPER}
install igc /sbin/modprobe --ignore-install igc \$CMDLINE_OPTS && /bin/sleep 1 && ${HELPER}

EOF
		echo "# options *=0 only when this kernel's module actually has that parameter"
		emit_eee_options
	} | write_root_file "$MODPROBE_CONF" 644
	refresh_initramfs
}

# blacklist_eee: write the modprobe blacklist, then kill live EEE
blacklist_eee() {
	echo -e "${yellowColour}EEE is a PHY feature, not a kernel module — 'blacklist eee' would do nothing.${endColour}"
	echo -e "${yellowColour}Blacklisting r8169/r8152 would take the ethernet card down. Not doing that.${endColour}"
	echo -e "${blueColour}Installing ${MODPROBE_CONF} (install hooks + any real EEE=0 params), then disabling live EEE.${endColour}"
	install_modprobe_rule
	disable_eee_now || true
	echo
	print_status || true
}

# install_udev_rule: NIC hotplug (USB r8152) and kernel re-add after a flap
install_udev_rule() {
	install_helper
	echo -e "${blueColour}Writing ${UDEV_RULE}${endColour}"
	write_root_file "$UDEV_RULE" 644 <<EOF
# Disable EEE as soon as a net interface is added. %k is the kernel iface name.
ACTION=="add", SUBSYSTEM=="net", KERNEL!="lo", RUN+="${HELPER} %k"
EOF
	if command -v udevadm >/dev/null 2>&1; then
		run_root udevadm control --reload-rules
		run_root udevadm trigger --subsystem-match=net --action=add
	fi
}

install_systemd_once() {
	install_helper
	echo -e "${blueColour}Writing ${SYSTEMD_ONCE}${endColour}"
	write_root_file "$SYSTEMD_ONCE" 644 <<EOF
[Unit]
Description=Disable Energy Efficient Ethernet once at boot
After=network-pre.target systemd-udevd.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${HELPER}

[Install]
WantedBy=multi-user.target
EOF
	if command -v systemctl >/dev/null 2>&1; then
		run_root systemctl daemon-reload
		run_root systemctl enable --now disable-eee.service
	fi
}

# install_watchdog: long-running loop — this is what stops the "comes back every few seconds" bug
install_watchdog() {
	install_helper
	echo -e "${blueColour}Writing ${SYSTEMD_WATCH}${endColour}"
	write_root_file "$SYSTEMD_WATCH" 644 <<EOF
[Unit]
Description=Keep Energy Efficient Ethernet disabled (respawn guard)
After=network-pre.target
Wants=network-pre.target

[Service]
Type=simple
ExecStart=${HELPER} --watch --interval ${WATCH_INTERVAL}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
	if command -v systemctl >/dev/null 2>&1; then
		run_root systemctl daemon-reload
		run_root systemctl enable --now eee-watchdog.service
	fi
}

# install_nm: dispatcher (any NM) plus ethtool.eee-enabled on ethernet profiles (NM 1.36+)
install_nm() {
	install_helper
	echo -e "${blueColour}Writing ${NM_DISPATCH}${endColour}"
	write_root_file "$NM_DISPATCH" 755 <<EOF
#!/bin/sh
# NetworkManager pre-up.d: \$1 is the interface about to come up.
[ -n "\$1" ] || exit 0
${HELPER} "\$1" || logger -t disable-eee "helper failed on \$1 (exit \$?)"
exit 0
EOF
	if command -v nmcli >/dev/null 2>&1; then
		local uuid name type
		# -t: terse NAME:UUID:TYPE so names with spaces stay one field
		while IFS=: read -r name uuid type; do
			[[ "$type" == "802-3-ethernet" ]] || continue
			echo -e "${cyanColour}NM profile ${name} (${uuid}): ethtool.eee-enabled off${endColour}"
			if ! run_root nmcli connection modify "$uuid" ethtool.eee-enabled off; then
				echo -e "${yellowColour}  nmcli could not set ethtool.eee-enabled on ${name} (older NM?). Dispatcher still covers it.${endColour}"
			fi
		done < <(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null || true)
	else
		echo -e "${yellowColour}nmcli not found; dispatcher only.${endColour}"
	fi
}

# refresh_initramfs: r8169 is often in the initramfs; the modprobe hook must be too
refresh_initramfs() {
	if command -v update-initramfs >/dev/null 2>&1; then
		echo -e "${blueColour}Rebuilding initramfs (update-initramfs -u)${endColour}"
		run_root update-initramfs -u
	elif command -v mkinitcpio >/dev/null 2>&1; then
		echo -e "${blueColour}Rebuilding initramfs (mkinitcpio -P)${endColour}"
		run_root mkinitcpio -P
	elif command -v dracut >/dev/null 2>&1; then
		echo -e "${blueColour}Rebuilding initramfs (dracut -f)${endColour}"
		run_root dracut -f
	else
		echo -e "${yellowColour}No update-initramfs / mkinitcpio / dracut. If r8169 is in your initramfs, rebuild it yourself.${endColour}"
	fi
}

uninstall_all() {
	echo -e "${yellowColour}Removing EEE persistence hooks...${endColour}"
	if command -v systemctl >/dev/null 2>&1; then
		run_root systemctl disable --now eee-watchdog.service 2>/dev/null || true
		run_root systemctl disable --now disable-eee.service 2>/dev/null || true
	fi
	local f
	for f in "$HELPER" "$MODPROBE_CONF" "$MODPROBE_CONF_OLD" "$UDEV_RULE" "$NM_DISPATCH" "$SYSTEMD_ONCE" "$SYSTEMD_WATCH"; do
		if [[ -e "$f" ]]; then
			echo -e "  remove ${f}"
			run_root rm -f "$f"
		fi
	done
	if command -v systemctl >/dev/null 2>&1; then
		run_root systemctl daemon-reload
	fi
	if command -v udevadm >/dev/null 2>&1; then
		run_root udevadm control --reload-rules
	fi
	if command -v nmcli >/dev/null 2>&1; then
		local uuid type
		while IFS=: read -r _name uuid type; do
			[[ "$type" == "802-3-ethernet" ]] || continue
			run_root nmcli connection modify "$uuid" ethtool.eee-enabled ignore 2>/dev/null || true
		done < <(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null || true)
	fi
	echo -e "${greenColour}Hooks removed. Live EEE state is unchanged — run --status.${endColour}"
}

# disable_eee_now: ethtool off + tx-lpi off, then re-read so we know if it stuck
disable_eee_now() {
	need_ethtool
	ensure_sudo
	local iface state note rc=0
	local -a ifaces=()
	# mapfile: slurp one iface name per line into the array
	mapfile -t ifaces < <(list_wired_ifaces)
	if [[ "${#ifaces[@]}" -eq 0 ]]; then
		echo -e "${yellowColour}No wired interfaces to act on.${endColour}"
		return 0
	fi
	for iface in "${ifaces[@]}"; do
		state=$(eee_state "$iface")
		case "$state" in
			unsupported)
				echo -e "${grayColour}${iface}: EEE not supported — skipped${endColour}"
				continue
				;;
			missing)
				echo -e "${redColour}${iface}: disappeared from the kernel${endColour}"
				rc=1
				continue
				;;
			disabled)
				echo -e "${greenColour}${iface}: EEE already disabled${endColour}"
				continue
				;;
		esac
		note=$(eee_active_note "$iface")
		echo -e "${yellowColour}${iface}: EEE is ${state}${note:+ (${note})} — turning it off${endColour}"
		if [[ "$DRY_RUN" -eq 1 ]]; then
			echo -e "${yellowColour}[dry-run]${endColour} ${ETHTOOL} --set-eee ${iface} eee off tx-lpi off"
			continue
		fi
		if ! run_root "$ETHTOOL" --set-eee "$iface" eee off tx-lpi off; then
			if ! run_root "$ETHTOOL" --set-eee "$iface" eee off; then
				echo -e "${redColour}${iface}: ethtool --set-eee failed${endColour}"
				rc=1
				continue
			fi
		fi
		state=$(eee_state "$iface")
		if [[ "$state" == "disabled" ]]; then
			echo -e "${greenColour}${iface}: EEE is now disabled${endColour}"
		else
			echo -e "${redColour}${iface}: ethtool returned success but EEE is still ${state}${endColour}"
			echo -e "${redColour}This is the respawn / refuses-to-stay-off failure. Use --blacklist, then --lock-down and --watch.${endColour}"
			rc=1
		fi
	done
	return "$rc"
}

# watch_loop: foreground monitor with colour; helper --watch is the headless version
watch_loop() {
	need_ethtool
	ensure_sudo
	echo -e "${blueColour}Watching EEE every ${WATCH_INTERVAL}s. Ctrl+C to stop.${endColour}"
	echo -e "${grayColour}If a line says CAME BACK, the driver or firmware re-armed EEE — that is the Arch bug.${endColour}"
	local iface state
	while true; do
		local -a ifaces=()
		# mapfile: refresh the NIC list each pass in case a card vanishes
		mapfile -t ifaces < <(list_wired_ifaces)
		if [[ "${#ifaces[@]}" -eq 0 ]]; then
			echo -e "${redColour}$(date '+%H:%M:%S')  no wired NICs in sysfs — card may have dropped${endColour}"
		fi
		for iface in "${ifaces[@]}"; do
			state=$(eee_state "$iface")
			case "$state" in
				disabled)
					echo -e "${greenColour}$(date '+%H:%M:%S')  ${iface}: EEE off${endColour}"
					;;
				unsupported)
					echo -e "${grayColour}$(date '+%H:%M:%S')  ${iface}: no EEE${endColour}"
					;;
				missing)
					echo -e "${redColour}$(date '+%H:%M:%S')  ${iface}: GONE${endColour}"
					;;
				enabled)
					echo -e "${redColour}$(date '+%H:%M:%S')  ${iface}: EEE CAME BACK — killing${endColour}"
					if [[ "$DRY_RUN" -eq 1 ]]; then
						echo -e "${yellowColour}[dry-run] would --set-eee ${iface} eee off${endColour}"
					else
						run_root "$ETHTOOL" --set-eee "$iface" eee off tx-lpi off 2>/dev/null \
							|| run_root "$ETHTOOL" --set-eee "$iface" eee off 2>/dev/null \
							|| echo -e "${redColour}  ethtool failed on ${iface}${endColour}"
					fi
					;;
				*)
					echo -e "${yellowColour}$(date '+%H:%M:%S')  ${iface}: ${state}${endColour}"
					;;
			esac
		done
		sleep "$WATCH_INTERVAL"
	done
}

explain_eee() {
	cat <<EOF

$(echo -e "${cyanColour}What Energy Efficient Ethernet is${endColour}")
EEE (IEEE 802.3az) is a PHY power-save. When the wire is idle the NIC tells
the switch "I am going to sleep" (Low Power Idle / LPI), then wakes for the
next frame. Fine on paper. On a lot of Realtek RTL8111/8168/8153 silicon
the handshake is buggy: the link flaps, speed drops to 100 Mb/s, or the
whole PCI/USB function disappears until reboot.

$(echo -e "${cyanColour}Why you cannot blacklist EEE as a module${endColour}")
There is no eee.ko. \`blacklist eee\` is a no-op. \`blacklist r8169\` (or
r8152) unloads the ethernet driver — that is the outage, not the fix.
r8169/r8152 also have no eee=0 module parameter on current kernels; a
fake options line can refuse to load the card. --blacklist writes
${MODPROBE_CONF}: install hooks that call ${HELPER} after the
driver loads, plus options *=0 only when modinfo lists that parm.

$(echo -e "${cyanColour}Why ethtool alone is not enough${endColour}")
    ethtool --set-eee <iface> eee off
is live-only. It dies on reboot, on suspend/resume, when NetworkManager
renegotiates the link, and when the driver reloads. On the Arch box that
started this script, EEE came back every few seconds and disabled the NIC
even after a successful --set-eee. That is why --lock-down / --watch exist
if the modprobe rule is not enough.

$(echo -e "${cyanColour}Hooks this script can install${endColour}")
  * ${HELPER}
      shared killer used by everything below
  * ${MODPROBE_CONF}
      the EEE "blacklist": install hooks after r8169 / r8152 / r8168 / igb / e1000e / igc load
  * ${UDEV_RULE}
      runs the helper when a net device is added (USB ethernet, post-flap)
  * ${NM_DISPATCH} + nmcli ethtool.eee-enabled=off
      NetworkManager pre-up (the unix.stackexchange.com 729508 answers)
  * ${SYSTEMD_ONCE}
      oneshot at boot
  * ${SYSTEMD_WATCH}
      loop that re-kills EEE if firmware/driver re-arms it

$(echo -e "${cyanColour}How to read --show-eee${endColour}")
  disabled                 good — EEE will not run
  enabled - inactive       armed. No LPI right now (often no partner / no link)
                           still dangerous: it can activate the moment the
                           switch answers
  enabled - active         napping right now — this is the state that flaps
                           Realtek cards

$(echo -e "${cyanColour}Suggested sequence on a box that already lost a NIC to EEE${endColour}")
  $0 --status
  $0 --blacklist      # modprobe rule + live disable (preferred first step)
  $0 --lock-down      # if EEE still comes back: udev, NM, systemd, watchdog
  $0 --watch          # leave running once and watch for CAME BACK lines
  journalctl -t eee-apply-off -f

Reference: https://unix.stackexchange.com/questions/729508/how-to-permanently-disable-eee-energy-efficient-ethernet-on-ethernet-card

EOF
}

# mark: [x] / [ ] with colour for the persistence inventory
mark() {
	if persist_present "$1"; then
		echo -e "  ${greenColour}[x]${endColour} $1"
	else
		echo -e "  ${grayColour}[ ]${endColour} $1"
	fi
}

# print_status: --status / --doctor / --report; exit 1 if EEE is still armed
print_status() {
	need_ethtool
	local iface state note drv bus fw risk oper spd enabled_count=0 eee_nics=0
	local -a ifaces=()

	echo -e "${blueColour}Energy Efficient Ethernet — status${endColour}"
	echo -e "${grayColour}EEE is IEEE 802.3az. The NIC naps on an idle wire. Realtek r8169/r8152"
	echo -e "often flap or drop the card instead. enabled-inactive is still armed.${endColour}"
	echo
	echo -e "  host:     $(hostname)   kernel: $(uname -r)"
	if [[ -r /etc/os-release ]]; then
		# shellcheck disable=SC1091
		. /etc/os-release
		echo -e "  os:       ${PRETTY_NAME:-unknown}"
	fi
	echo -e "  ethtool:  ${ETHTOOL}"
	echo

	# mapfile: slurp one iface name per line into the array
	mapfile -t ifaces < <(list_wired_ifaces)
	if [[ "${#ifaces[@]}" -eq 0 ]]; then
		echo -e "${redColour}No wired NICs in /sys/class/net.${endColour}"
		echo -e "${redColour}If you expected ethernet here, the card may already be gone — that is the EEE failure mode.${endColour}"
	fi

	for iface in "${ifaces[@]}"; do
		state=$(eee_state "$iface")
		note=$(eee_active_note "$iface")
		drv=$(iface_driver "$iface")
		bus=$(iface_bus "$iface")
		fw=$(iface_fw "$iface")
		risk=$(driver_risk "$drv")
		oper=$(iface_operstate "$iface")
		spd=$(iface_speed "$iface")

		echo -e "${purpleColour}==> ${iface}${endColour}"
		echo -e "    driver:   ${drv:-?}   bus: ${bus:-?}   fw: ${fw:-?}"
		echo -e "    link:     ${oper}   speed: ${spd}"
		if [[ "$risk" == "HIGH" ]]; then
			echo -e "    risk:     ${redColour}HIGH${endColour}  (${drv} is the usual EEE-kills-the-NIC family)"
		elif [[ "$risk" == "MED" ]]; then
			echo -e "    risk:     ${yellowColour}MED${endColour}   (${drv} has had EEE bugs on some firmware)"
		else
			echo -e "    risk:     ${grayColour}${risk}${endColour}"
		fi

		case "$state" in
			disabled)
				echo -e "    EEE:      ${greenColour}disabled${endColour}   (not running)"
				eee_nics=$((eee_nics + 1))
				;;
			enabled)
				eee_nics=$((eee_nics + 1))
				enabled_count=$((enabled_count + 1))
				if [[ "$note" == "active" ]]; then
					echo -e "    EEE:      ${redColour}ENABLED — ACTIVE${endColour}   (in Low Power Idle right now)"
				elif [[ "$note" == "inactive" ]]; then
					echo -e "    EEE:      ${redColour}ENABLED — inactive${endColour}   (armed; will LPI when the partner allows)"
				else
					echo -e "    EEE:      ${redColour}ENABLED${endColour}"
				fi
				eee_raw "$iface" | sed 's/^/    /'
				;;
			unsupported)
				echo -e "    EEE:      ${grayColour}not supported${endColour}"
				;;
			missing)
				echo -e "    EEE:      ${redColour}device missing${endColour}"
				enabled_count=$((enabled_count + 1))
				;;
			*)
				echo -e "    EEE:      ${yellowColour}${state}${endColour}"
				eee_raw "$iface" | sed 's/^/    /'
				;;
		esac
		echo
	done

	echo -e "${blueColour}Persistence (blacklist-eee.conf + other hooks)${endColour}"
	mark "$HELPER"
	mark "$MODPROBE_CONF"
	mark "$UDEV_RULE"
	mark "$NM_DISPATCH"
	mark "$SYSTEMD_ONCE"
	mark "$SYSTEMD_WATCH"
	if command -v systemctl >/dev/null 2>&1; then
		echo -e "    disable-eee.service : $(unit_active disable-eee.service)"
		echo -e "    eee-watchdog.service: $(unit_active eee-watchdog.service)"
	fi
	if command -v nmcli >/dev/null 2>&1; then
		local name uuid type eeeprop
		echo -e "    NetworkManager ethernet profiles:"
		local any_nm=0
		while IFS=: read -r name uuid type; do
			[[ "$type" == "802-3-ethernet" ]] || continue
			any_nm=1
			eeeprop=$(nmcli -g ethtool.eee-enabled connection show "$uuid" 2>/dev/null || echo '?')
			if [[ "$eeeprop" == "off" || "$eeeprop" == "0" || "$eeeprop" == "no" ]]; then
				echo -e "      ${greenColour}${name}${endColour}: ethtool.eee-enabled=${eeeprop}"
			else
				echo -e "      ${yellowColour}${name}${endColour}: ethtool.eee-enabled=${eeeprop:-unset}"
			fi
		done < <(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null || true)
		[[ "$any_nm" -eq 0 ]] && echo -e "      ${grayColour}(none)${endColour}"
	fi
	echo

	echo -e "${blueColour}Verdict${endColour}"
	if [[ "$enabled_count" -gt 0 ]]; then
		echo -e "  ${redColour}EEE IS RUNNING (or armed) on ${enabled_count} NIC(s).${endColour}"
		if persist_present "$SYSTEMD_WATCH" && [[ "$(unit_active eee-watchdog.service)" == "active" ]]; then
			echo -e "  ${redColour}Watchdog is active and EEE is still on — the driver is winning. Check journalctl -t eee-apply-off${endColour}"
		elif persist_present "$HELPER"; then
			echo -e "  ${yellowColour}Hooks exist but EEE is live. Run: $0 --disable-eee${endColour}"
			echo -e "  ${yellowColour}Then: systemctl enable --now eee-watchdog.service   (or $0 --install-watchdog)${endColour}"
		else
			echo -e "  ${yellowColour}Nothing will survive a reboot. Blacklist it, then lock it if it still runs:${endColour}"
			echo -e "    $0 --blacklist"
			echo -e "    $0 --lock-down"
		fi
	elif [[ "$eee_nics" -gt 0 ]]; then
		echo -e "  ${greenColour}EEE is not running on any EEE-capable wired NIC.${endColour}"
		if persist_present "$HELPER" && persist_present "$MODPROBE_CONF"; then
			echo -e "  ${greenColour}Modprobe blacklist is in place (${MODPROBE_CONF}).${endColour}"
		else
			echo -e "  ${yellowColour}Off right now, but not persistent. Next reboot can bring EEE back.${endColour}"
			echo -e "  ${yellowColour}Blacklist it: $0 --blacklist${endColour}"
		fi
	else
		echo -e "  ${grayColour}No EEE-capable wired NIC reported. If the card vanished, that is the bug — reboot and --blacklist before the link comes up.${endColour}"
	fi
	echo
	echo -e "${grayColour}This script took ${SECONDS} seconds.${endColour}"

	if [[ "$enabled_count" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# lock_down: --lock-down / --lockdown / --install-all — belt and suspenders if --blacklist is not enough
lock_down() {
	echo -e "${greenColour}==>${endColour} ${blueColour}Disabling EEE now, then installing every persist hook.${endColour}"
	disable_eee_now || true
	install_modprobe_rule
	install_udev_rule
	install_systemd_once
	install_nm
	install_watchdog
	echo
	echo -e "${greenColour}Lock-down finished. Re-checking live state...${endColour}"
	echo
	print_status || true
	echo -e "${cyanColour}Leave a watch running once if this box is the one that respawned EEE:${endColour}"
	echo -e "  $0 --watch"
	echo -e "  journalctl -u eee-watchdog -f"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--status|-s|--doctor|--report) ACTION="status" ;;
		--explain|--what-is-eee) ACTION="explain" ;;
		--disable-eee|--kill|-d|--off) ACTION="disable" ;;
		--watch) ACTION="watch" ;;
		--interval)
			WATCH_INTERVAL="${2:-}"
			if [[ ! "$WATCH_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
				echo " --interval needs a positive integer" >&2
				exit 2
			fi
			shift
			;;
		--iface)
			if [[ -z "${2:-}" ]]; then
				echo "--iface needs a name" >&2
				exit 2
			fi
			IFACE_FILTER+=("$2")
			shift
			;;
		--blacklist) ACTION="blacklist" ;;
		--install-modprobe-rule) ACTION="modprobe" ;;
		--install-udev-rule) ACTION="udev" ;;
		--install-systemd) ACTION="systemd" ;;
		--install-nm) ACTION="nm" ;;
		--install-watchdog) ACTION="watchdog" ;;
		--install-all|--lock-down|--lockdown|--never-again) ACTION="lockdown" ;;
		--uninstall) ACTION="uninstall" ;;
		--dry-run|-n) DRY_RUN=1 ;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 2
			;;
	esac
	shift
done

[[ -z "$ACTION" ]] && ACTION="status"

if [[ "$DRY_RUN" -eq 1 ]]; then
	echo -e "${yellowColour}DRY-RUN: no ethtool writes, no files, no systemd changes.${endColour}"
fi

case "$ACTION" in
	status) print_status ;;
	explain) explain_eee ;;
	disable) disable_eee_now ;;
	watch) watch_loop ;;
	blacklist) blacklist_eee ;;
	modprobe) install_modprobe_rule ;;
	udev) install_udev_rule ;;
	systemd) install_systemd_once ;;
	nm) install_nm ;;
	watchdog) install_watchdog ;;
	lockdown) lock_down ;;
	uninstall) uninstall_all ;;
	*)
		usage >&2
		exit 2
		;;
esac
