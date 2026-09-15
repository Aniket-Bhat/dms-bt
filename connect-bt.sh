#!/usr/bin/env bash

# bt-connect.sh — List available Bluetooth devices and connect by number

set -euo pipefail

# -- Resize terminal to 69 cols x 10 rows via ANSI escape ---------------------
printf '\033[8;10;69t'

# -- Colours -------------------------------------------------------------------
BOLD='\033[1m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

# -- Sanity check --------------------------------------------------------------
if ! command -v bluetoothctl &>/dev/null; then
    echo -e "${RED}Error:${RESET} bluetoothctl not found. Is bluez installed?" >&2
    exit 1
fi

# -- Collect all paired devices ------------------------------------------------
echo -e "\n${CYAN}${BOLD}Scanning for available Bluetooth devices...${RESET}\n"

mapfile -t raw_devices < <(bluetoothctl devices 2>/dev/null)

if [[ ${#raw_devices[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No paired devices found.${RESET}"
    echo "Pair a device first with:  bluetoothctl pair <MAC>"
    exit 0
fi

# -- Filter to reachable devices only, track connected state -------------------
# A device is "available" if bluetoothctl info reports an RSSI value (in range)
# or is currently connected. Offline/out-of-range devices are silently skipped.
declare -a mac=()
declare -a name=()
declare -A connected=()

for line in "${raw_devices[@]}"; do
    if [[ $line =~ ^Device[[:space:]]([0-9A-Fa-f:]{17})[[:space:]](.+)$ ]]; then
        m="${BASH_REMATCH[1]}"
        n="${BASH_REMATCH[2]}"
        info=$(bluetoothctl info "$m" 2>/dev/null)
        is_connected=false
        is_available=false
        if echo "$info" | grep -q "Connected: yes"; then
            is_connected=true
            is_available=true
        fi
        if echo "$info" | grep -qE "RSSI:"; then
            is_available=true
        fi
        if $is_available; then
            mac+=("$m")
            name+=("$n")
            $is_connected && connected["$m"]=1
        fi
    fi
done

if [[ ${#mac[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No available devices found nearby.${RESET}"
    echo "Make sure your devices are powered on and in range."
    exit 0
fi

# -- Display numbered list -----------------------------------------------------
echo -e "${BOLD}Available devices:${RESET}\n"
for i in "${!mac[@]}"; do
    if [[ -n "${connected[${mac[$i]}]+_}" ]]; then
        printf "  ${CYAN}%2d${RESET}  %-40s  ${YELLOW}%s${RESET}  ${GREEN}[connected]${RESET}\n" \
            $((i + 1)) "${name[$i]}" "${mac[$i]}"
    else
        printf "  ${CYAN}%2d${RESET}  %-40s  ${YELLOW}%s${RESET}\n" \
            $((i + 1)) "${name[$i]}" "${mac[$i]}"
    fi
done

echo ""

# -- Resolve which device to act on -------------------------------------------
max=${#mac[@]}
auto_connect=false

if [[ $max -eq 1 && -z "${connected[${mac[0]}]+_}" ]]; then
    # Only one device and it is not already connected: start countdown
    auto_connect=true
    secs=3
    echo -ne "$(echo -e "Only one device found. Auto-connecting to ${GREEN}${BOLD}${name[0]}${RESET} in ")"
    while (( secs > 0 )); do
        echo -ne "${BOLD}${secs}${RESET}... "
        if read -rsn1 -t 1 key 2>/dev/null; then
            echo -e "\n${YELLOW}Auto-connect cancelled.${RESET}"
            auto_connect=false
            if [[ "$key" == "q" || "$key" == "Q" ]]; then
                echo "Bye!" && exit 0
            elif [[ "$key" == "1" ]]; then
                # Pressed the only valid number — connect immediately
                auto_connect=true
            fi
            break
        fi
        (( secs-- ))
    done
    echo ""
    selected_mac="${mac[0]}"
    selected_name="${name[0]}"
else
    # Manual selection (single keypress, no Enter needed)
    while true; do
        echo -ne "$(echo -e "Press a key ${BOLD}[1-${max}]${RESET} to connect/disconnect, or ${BOLD}q${RESET} to quit: ")"
        read -rsn1 choice
        echo "$choice"

        [[ "$choice" == "q" || "$choice" == "Q" ]] && echo "Bye!" && exit 0

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= max )); then
            break
        fi

        echo -e "${RED}Invalid key.${RESET} Press a number between 1 and ${max}."
    done

    idx=$(( choice - 1 ))
    selected_mac="${mac[$idx]}"
    selected_name="${name[$idx]}"
fi

# -- Connect or disconnect -----------------------------------------------------
# Auto-connect path: always connect, never disconnect automatically.
# Manual path: toggle (connect if disconnected, disconnect if connected).
if $auto_connect || [[ -z "${connected[$selected_mac]+_}" ]]; then
    echo -e "\n${BOLD}Connecting to:${RESET} ${GREEN}${selected_name}${RESET} (${selected_mac})...\n"
    if bluetoothctl connect "$selected_mac"; then
        echo -e "\n${GREEN}${BOLD}Connected to ${selected_name}${RESET}"
    else
        echo -e "\n${RED}${BOLD}Failed to connect to ${selected_name}.${RESET}"
        echo "Make sure the device is powered on and in range."
        exit 1
    fi
else
    echo -e "\n${BOLD}Disconnecting from:${RESET} ${YELLOW}${selected_name}${RESET} (${selected_mac})...\n"
    if bluetoothctl disconnect "$selected_mac"; then
        echo -e "\n${YELLOW}${BOLD}Disconnected from ${selected_name}${RESET}"
    else
        echo -e "\n${RED}${BOLD}Failed to disconnect from ${selected_name}.${RESET}"
        exit 1
    fi
fi
