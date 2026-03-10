#!/bin/sh
# Downloads latest gl-tailscale-fix package, verifies checksum, installs via opkg.
set -eu

BASE_URL="${BASE_URL:-https://github.com/RemoteToHome-io/gl-tailscale-fix/releases/latest/download}"
IPK_NAME="${IPK_NAME:-gl-tailscale-fix_latest_all.ipk}"
SHA_NAME="${IPK_NAME}.sha256"
TMP_DIR="${TMPDIR:-/tmp}"

IPK_PATH="${TMP_DIR}/${IPK_NAME}"
SHA_PATH="${TMP_DIR}/${SHA_NAME}"

download_file() {
    src="$1"
    dst="$2"

    if command -v wget >/dev/null 2>&1; then
        wget -q "$src" -O "$dst"
        return 0
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$src" -o "$dst"
        return 0
    fi

    echo "Error: neither wget nor curl is available." >&2
    return 1
}

verify_checksum() {
    if command -v sha256sum >/dev/null 2>&1; then
        (
            cd "${TMP_DIR}"
            sha256sum -c "${SHA_NAME}"
        )
        return 0
    fi

    if command -v openssl >/dev/null 2>&1; then
        expected=$(awk '{print $1}' "${SHA_PATH}")
        actual=$(openssl dgst -sha256 "${IPK_PATH}" | awk '{print $NF}')
        if [ "$expected" = "$actual" ]; then
            echo "${IPK_NAME}: OK"
            return 0
        fi
        echo "${IPK_NAME}: FAILED" >&2
        return 1
    fi

    echo "Error: neither sha256sum nor openssl is available." >&2
    return 1
}

echo "Downloading ${IPK_NAME}..."
download_file "${BASE_URL}/${IPK_NAME}" "${IPK_PATH}"

echo "Downloading ${SHA_NAME}..."
download_file "${BASE_URL}/${SHA_NAME}" "${SHA_PATH}"

echo "Verifying checksum..."
verify_checksum

# Restore original GL wrapper if present before package install.
if [ -f '/rom/usr/bin/gl_tailscale' ]; then
    echo "Restoring original GL wrapper before package installation..."
    if ! cp '/rom/usr/bin/gl_tailscale' '/usr/bin/gl_tailscale'; then
        echo "Warning: Could not restore /usr/bin/gl_tailscale from /rom; continuing installation." >&2
    fi
fi

echo "Installing package..."
if ! command -v opkg >/dev/null 2>&1; then
    echo "Error: opkg is required to install ${IPK_NAME}." >&2
    exit 1
fi
opkg install "${IPK_PATH}"

echo "Done."
