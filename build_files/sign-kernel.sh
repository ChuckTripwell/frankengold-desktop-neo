#!/usr/bin/env bash
set -euo pipefail

log() { echo "[custom-kernel] $*"; }
error() { echo "[custom-kernel] Error: $*"; exit 1; }

SIGNING_KEY="/MOK.priv"
SIGNING_CERT="/workspace/build_files/MOK.pem"
MOK_CERT="/usr/share/cert/MOK.der"

cleanup() {
    rm -f "$SIGNING_KEY"
}
trap cleanup EXIT

log "Extracting and validating keys..."
if [[ "${KERNEL_SECRET:-}" == *'\n'* ]]; then
    printf '%b' "${KERNEL_SECRET//\\n/$'\n'}" > "$SIGNING_KEY"
else
    printf '%s' "${KERNEL_SECRET:-}" > "$SIGNING_KEY"
fi
chmod 600 "$SIGNING_KEY"

openssl pkey -in "$SIGNING_KEY" -noout >/dev/null 2>&1 || error "Invalid private key"
openssl x509 -in "$SIGNING_CERT" -noout >/dev/null 2>&1 || error "Invalid X509 cert"

KERNEL_DIR="$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -name "[0-9]*" | sort -V | tail -n 1)"
[[ -n "$KERNEL_DIR" ]] || error "No kernel directory found"
KERNEL_VER="$(basename "$KERNEL_DIR")"
VMLINUZ="$KERNEL_DIR/vmlinuz"

log "Signing kernel: $KERNEL_VER"
SIGNED_VMLINUZ=$(mktemp)
sbsign --key "$SIGNING_KEY" --cert "$SIGNING_CERT" --output "$SIGNED_VMLINUZ" "$VMLINUZ"
install -m 0644 "$SIGNED_VMLINUZ" "$VMLINUZ"
rm -f "$SIGNED_VMLINUZ"

SIGN_FILE="$KERNEL_DIR/build/scripts/sign-file"
[[ -x "$SIGN_FILE" ]] || error "sign-file missing or not executable"

log "Signing modules..."
find "$KERNEL_DIR" -type f \( -name "*.ko" -o -name "*.ko.xz" -o -name "*.ko.zst" -o -name "*.ko.gz" \) | while read -r mod; do
    case "$mod" in
        *.ko)
            "$SIGN_FILE" sha256 "$SIGNING_KEY" "$SIGNING_CERT" "$mod"
            ;;
        *.ko.xz)
            raw="${mod%.xz}"
            xz -d -q "$mod" && "$SIGN_FILE" sha256 "$SIGNING_KEY" "$SIGNING_CERT" "$raw" && xz -z -q -T0 "$raw"
            ;;
        *.ko.zst)
            raw="${mod%.zst}"
            zstd -d -q --rm "$mod" && "$SIGN_FILE" sha256 "$SIGNING_KEY" "$SIGNING_CERT" "$raw" && zstd -q -T0 --rm "$raw"
            ;;
        *.ko.gz)
            raw="${mod%.gz}"
            gzip -d -q -f "$mod" && "$SIGN_FILE" sha256 "$SIGNING_KEY" "$SIGNING_CERT" "$raw" && gzip -q -f "$raw"
            ;;
    esac
done

depmod -b / -a "$KERNEL_VER"

log "Configuring MOK enrollment service..."
mkdir -p /usr/share/cert /usr/lib/systemd/system
openssl x509 -in "$SIGNING_CERT" -outform DER -out "$MOK_CERT"

SERVICE="/usr/lib/systemd/system/mok-enroll.service"
echo "[Unit]" > "$SERVICE"
echo "Description=Enroll MOK key after GUI starts" >> "$SERVICE"
echo "ConditionPathExists=!/etc/mok_successfully_enrolled.lock" >> "$SERVICE"
echo "After=graphical.target" >> "$SERVICE"
echo "" >> "$SERVICE"
echo "[Service]" >> "$SERVICE"
echo "Type=oneshot" >> "$SERVICE"
echo "RemainAfterExit=yes" >> "$SERVICE"
echo "ExecStart=/bin/bash -c 'yes universalblue | mokutil --import /usr/share/cert/MOK.der && touch /etc/.mok_successfully_enrolled.lock'" >> "$SERVICE"
echo "" >> "$SERVICE"
echo "[Install]" >> "$SERVICE"
echo "WantedBy=graphical.target" >> "$SERVICE"

chmod 0644 "$SERVICE"
mkdir -p /usr/lib/systemd/system/sysinit.target.wants
ln -sf "$SERVICE" /usr/lib/systemd/system/sysinit.target.wants/mok-enroll.service

sbverify --cert "$SIGNING_CERT" "$VMLINUZ" >/dev/null 2>&1 || error "Verification failed."
log "Kernel signing complete."
