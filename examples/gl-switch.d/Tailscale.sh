#!/bin/sh
#
# Toggle Tailscale (GL native) + Kill Switch (gl-tailscale-fix) together
# via the physical side switch on supported GL.iNet routers (Beryl AX,
# Slate AX, etc.).
#
# Install on the router:
#   wget -q https://raw.githubusercontent.com/RemoteToHome-io/gl-tailscale-fix/main/examples/gl-switch.d/Tailscale.sh -O /etc/gl-switch.d/Tailscale.sh
#   chmod +x /etc/gl-switch.d/Tailscale.sh
#
# Then edit DEFAULT_EXIT_NODE_IP below to a real Tailscale IP that should
# be used the FIRST time the switch is flipped to "on" (before you've ever
# picked an exit node in the GL UI). After that, the script reuses whatever
# exit node is currently selected in GL's UI — so changing your exit node
# selection in the UI sticks across switch toggles, and a tailnet with
# multiple available exit nodes works as expected.
#
# By default this script treats slider "on" as "enable Tailscale + kill
# switch" and slider "off" as "disable everything." If you prefer the
# inverted convention (resting position is "off" with Tailscale active),
# swap the action names in the if/elif branches below.
#
# Requires gl-tailscale-fix v1.0.9 or later for the kill switch RPC.
# Released under the same terms as gl-tailscale-fix (GPL-3.0).

# --- Configuration ---
DEFAULT_EXIT_NODE_IP="XX.XX.XX.XX"   # Used only on first run / when GL has no selection
LAN_ENABLED=false                     # Allow Remote Access LAN (true/false)
WAN_ENABLED=false                     # Allow Remote Access WAN (true/false)

# --- Logic ---
action=$1

if [ "$action" = "on" ]; then
    # Reuse GL's most recently selected exit node IP; fall back to default
    # only when GL has nothing set (first run or after a manual clear).
    exit_node_ip=$(uci -q get tailscale.settings.exit_node_ip)
    [ -z "$exit_node_ip" ] && exit_node_ip="$DEFAULT_EXIT_NODE_IP"

    # Enable Tailscale via GL's RPC, passing the resolved exit node IP.
    curl -H 'glinet: 1' -s -k http://127.0.0.1/rpc -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"tailscale\",\"set_config\",{\"enabled\":true,\"lan_enabled\":$LAN_ENABLED,\"wan_enabled\":$WAN_ENABLED,\"exit_node_ip\":\"$exit_node_ip\"}],\"id\":1}"

    sleep 5

    # Engage the kill switch in lock-step with Tailscale.
    curl -H 'glinet: 1' -s -k http://127.0.0.1/rpc -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"ts-fix\",\"set_config\",{\"kill_switch\":true}],\"id\":2}"

elif [ "$action" = "off" ]; then
    # Disable Tailscale via UCI directly, bypassing GL's RPC. This
    # preserves tailscale.settings.exit_node_ip so the next "on" flip
    # reconnects to the same node — calling GL's set_config would clear
    # it. The gl-tailscale-fix watchdog detects the enabled=0 transition
    # and tears down the kill switch routing rules within ~5 seconds.
    uci set tailscale.settings.enabled='0'
    uci commit tailscale
    /usr/bin/gl_tailscale restart >/dev/null 2>&1 &

else
    echo "Usage: $0 [on|off]" >&2
    exit 1
fi
