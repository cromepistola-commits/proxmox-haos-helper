#!/usr/bin/env bash

# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# Recompiled by: BigP5527
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE

function header_info {
  clear
  cat <<"EOF"
    __  __                        ___              _      __              __     ____  _____
   / / / /___  ____ ___  ___     /   |  __________(_)____/ /_____ _____  / /_   / __ \/ ___/
  / /_/ / __ \/ __ `__ \/ _ \   / /| | / ___/ ___/ / ___/ __/ __ `/ __ \/ __/  / / / /\__ \
 / __  / /_/ / / / / / /  __/  / ___ |(__  |__  ) (__  ) /_/ /_/ / / / / /_   / /_/ /___/ /
/_/ /_/\____/_/ /_/ /_/\___/  /_/  |_/____/____/_/____/\__/\__,_/_/ /_/\__/   \____//____/

EOF
}
header_info
echo -e "\n Loading..."

# Check for jq dependency
if ! command -v jq &> /dev/null; then
  echo -e "\n❌ jq is not installed. Installing..."
  apt-get update && apt-get install -y jq
fi

GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
NEXTID=$(pvesh get /cluster/nextid)

# Get HAOS versions using GitHub API
get_haos_version() {
  local channel="$1"
  local url=""
  
  if [ "$channel" == "dev" ]; then
    # For dev channel, use artifacts API
    url="https://os-artifacts.home-assistant.io/artifact?channel=dev&arch=intel-nuc&type=ova&version=latest"
    curl -s "$url" | jq -r '.url // empty'
  else
    # For stable/beta, use GitHub releases
    local api_url="https://api.github.com/repos/home-assistant/operating-system/releases"
    if [ "$channel" == "stable" ]; then
      curl -s "$api_url/latest" | jq -r '.assets[] | select(.name | test("haos_ova-.*\\.qcow2\\.xz$")) | .browser_download_url'
    else
      curl -s "$api_url" | jq -r '.[] | select(.prerelease == true) | .assets[] | select(.name | test("haos_ova-.*\\.qcow2\\.xz$")) | .browser_download_url' | head -1
    fi
  fi
}

# Get version strings
get_version_string() {
  local url="$1"
  if [ -n "$url" ]; then
    echo "$url" | grep -o 'haos_ova-[^/]*\.qcow2\.xz' | sed 's/haos_ova-//; s/\.qcow2\.xz//'
  else
    echo "unknown"
  fi
}

# Fetch URLs for each channel
STABLE_URL=$(get_haos_version "stable")
BETA_URL=$(get_haos_version "beta")
DEV_URL=$(get_haos_version "dev")

# Get version strings for display
STABLE_VER=$(get_version_string "$STABLE_URL")
BETA_VER=$(get_version_string "$BETA_URL")
DEV_VER=$(get_version_string "$DEV_URL")

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
HA=$(echo "\033[1;34m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD=" "
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
THIN="discard=on,ssd=1,"
SPINNER_PID=""
set -Eeuo pipefail
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

function error_handler() {
  if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID > /dev/null; then
    kill $SPINNER_PID > /dev/null 2>&1
  fi
  printf "\e[?25h"
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
  cleanup_vmid
}

function cleanup_vmid() {
  if [ -n "${VMID:-}" ] && qm status $VMID &>/dev/null; then
    qm stop $VMID &>/dev/null
    qm destroy $VMID &>/dev/null
  fi
}

function cleanup() {
  popd >/dev/null 2>&1 || true
  [ -d "${TEMP_DIR:-}" ] && rm -rf "$TEMP_DIR"
}

TEMP_DIR=$(mktemp -d)
pushd "$TEMP_DIR" >/dev/null

if whiptail --backtitle "Proxmox VE Helper Scripts" --title "HOME ASSISTANT OS VM" --yesno "This will create a New Home Assistant OS VM. Proceed?" 10 58; then
  :
else
  header_info && echo -e "⚠ User exited script \n" && exit
fi

function spinner() {
    local chars="/-\|"
    local spin_i=0
    printf "\e[?25l"
    while true; do
        printf "\r \e[36m%s\e[0m" "${chars:spin_i++%${#chars}:1}"
        sleep 0.1
    done
}

function msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}   "
  spinner &
  SPINNER_PID=$!
}

function msg_ok() {
  if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID > /dev/null; then
    kill $SPINNER_PID > /dev/null 2>&1
  fi
  printf "\e[?25h"
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

function msg_error() {
  if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID > /dev/null; then
    kill $SPINNER_PID > /dev/null 2>&1
  fi
  printf "\e[?25h"
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

function check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    clear
    msg_error "Please run this script as root."
    echo -e "\nExiting..."
    sleep 2
    exit
  fi
}

function pve_check() {
  local pve_version=$(pveversion | grep -oE "pve-manager/[0-9]+\.[0-9]+" | cut -d'/' -f2)
  if [[ "$pve_version" =~ ^8\.[0-9]+$ ]] || [[ "$pve_version" =~ ^9\.[0-9]+$ ]]; then
    return 0
  else
    msg_error "This version of Proxmox Virtual Environment is not supported"
    echo -e "Requires Proxmox Virtual Environment Version 8.x or 9.x."
    echo -e "Exiting..."
    sleep 2
    exit
  fi
}

function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    msg_error "This script will not work with PiMox or ARM architecture! \n"
    echo -e "Exiting..."
    sleep 2
    exit
  fi
}

function ssh_check() {
  if command -v pveversion >/dev/null 2>&1; then
    if [ -n "${SSH_CLIENT:+x}" ]; then
      if whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno --title "SSH DETECTED" --yesno "It's suggested to use the Proxmox shell instead of SSH, since SSH can create issues while gathering variables. Would you like to proceed with using SSH?" 10 62; then
        echo "you've been warned"
      else
        clear
        exit
      fi
    fi
  fi
}

function exit-script() {
  clear
  echo -e "⚠  User exited script \n"
  exit
}

function default_settings() {
  BRANCH="stable"
  HAOS_URL="$STABLE_URL"
  HAOS_VER="$STABLE_VER"
  VMID="$NEXTID"
  FORMAT=",efitype=4m"
  MACHINE=""
  DISK_CACHE="cache=writethrough,"
  HN="haos-$STABLE_VER"
  CPU_TYPE=" -cpu host"
  CORE_COUNT="4"
  RAM_SIZE="4096"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  START_VM="yes"
  
  # Clean hostname (remove invalid characters)
  HN=$(echo "$HN" | tr -cd '[:alnum:]-.' | sed 's/\./-/g' | cut -c1-63)
  
  echo -e "${DGN}Using HAOS Version: ${BGN}${HAOS_VER}${CL}"
  echo -e "${DGN}Using Virtual Machine ID: ${BGN}${VMID}${CL}"
  echo -e "${DGN}Using Machine Type: ${BGN}i440fx${CL}"
  echo -e "${DGN}Using Disk Cache: ${BGN}Write Through${CL}"
  echo -e "${DGN}Using Hostname: ${BGN}${HN}${CL}"
  echo -e "${DGN}Using CPU Model: ${BGN}Host${CL}"
  echo -e "${DGN}Allocated Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${DGN}Allocated RAM: ${BGN}${RAM_SIZE}${CL}"
  echo -e "${DGN}Using Bridge: ${BGN}${BRG}${CL}"
  echo -e "${DGN}Using MAC Address: ${BGN}${MAC}${CL}"
  echo -e "${DGN}Using VLAN: ${BGN}Default${CL}"
  echo -e "${DGN}Using Interface MTU Size: ${BGN}Default${CL}"
  echo -e "${DGN}Start VM when completed: ${BGN}yes${CL}"
  echo -e "${BL}Creating a HAOS VM using the above default settings${CL}"
}

function advanced_settings() {
  # Channel selection
  if BRANCH=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "HAOS VERSION" --radiolist "Choose Version" --cancel-button Exit-Script 12 58 3 \
    "stable" "Stable (${STABLE_VER})" ON \
    "beta" "Beta (${BETA_VER})" OFF \
    "dev" "Dev (${DEV_VER})" OFF \
    3>&1 1>&2 2>&3); then
    # Set URL and version based on selection
    case "$BRANCH" in
      "stable")
        HAOS_URL="$STABLE_URL"
        HAOS_VER="$STABLE_VER"
        ;;
      "beta")
        HAOS_URL="$BETA_URL"
        HAOS_VER="$BETA_VER"
        ;;
      "dev")
        HAOS_URL="$DEV_URL"
        HAOS_VER="$DEV_VER"
        ;;
    esac
    
    if [ -z "$HAOS_URL" ]; then
      msg_error "Failed to get download URL for $BRANCH channel"
      exit-script
    fi
    
    echo -e "${DGN}Using HAOS Version: ${BGN}$HAOS_VER${CL}"
  else
    exit-script
  fi

  # VM ID
  while true; do
    if VMID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Virtual Machine ID" 8 58 $NEXTID --title "VIRTUAL MACHINE ID" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      if [ -z "$VMID" ]; then
        VMID="$NEXTID"
      fi
      
      # Validate VMID is a number
      if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
        msg_error "VMID must be a number"
        continue
      fi
      
      # Check if VMID already exists
      if qm status "$VMID" &>/dev/null; then
        msg_error "VM ID $VMID is already in use"
        sleep 2
        continue
      fi
      
      echo -e "${DGN}Virtual Machine ID: ${BGN}$VMID${CL}"
      break
    else
      exit-script
    fi
  done

  # Machine Type
  if MACH=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "MACHINE TYPE" --radiolist --cancel-button Exit-Script "Choose Type" 10 58 2 \
    "i440fx" "Machine i440fx" ON \
    "q35" "Machine q35" OFF \
    3>&1 1>&2 2>&3); then
    if [ "$MACH" = "q35" ]; then
      echo -e "${DGN}Using Machine Type: ${BGN}$MACH${CL}"
      FORMAT=""
      MACHINE=" -machine q35"
    else
      echo -e "${DGN}Using Machine Type: ${BGN}$MACH${CL}"
      FORMAT=",efitype=4m"
      MACHINE=""
    fi
  else
    exit-script
  fi

  # Disk Cache
  if DISK_CACHE1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DISK CACHE" --radiolist "Choose" --cancel-button Exit-Script 10 58 2 \
    "0" "None" OFF \
    "1" "Write Through (Default)" ON \
    3>&1 1>&2 2>&3); then
    if [ "$DISK_CACHE1" = "1" ]; then
      echo -e "${DGN}Using Disk Cache: ${BGN}Write Through${CL}"
      DISK_CACHE="cache=writethrough,"
    else
      echo -e "${DGN}Using Disk Cache: ${BGN}None${CL}"
      DISK_CACHE=""
    fi
  else
    exit-script
  fi

  # Hostname
  if VM_NAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Hostname" 8 58 "haos-$HAOS_VER" --title "HOSTNAME" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$VM_NAME" ]; then
      HN="haos-$HAOS_VER"
    else
      HN=$(echo "${VM_NAME,,}" | tr -cd '[:alnum:]-.' | sed 's/\./-/g' | cut -c1-63)
    fi
    echo -e "${DGN}Using Hostname: ${BGN}$HN${CL}"
  else
    exit-script
  fi

  # CPU Type
  if CPU_TYPE1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "CPU MODEL" --radiolist "Choose" --cancel-button Exit-Script 10 58 2 \
    "0" "KVM64" OFF \
    "1" "Host (Default)" ON \
    3>&1 1>&2 2>&3); then
    if [ "$CPU_TYPE1" = "1" ]; then
      echo -e "${DGN}Using CPU Model: ${BGN}Host${CL}"
      CPU_TYPE=" -cpu host"
    else
      echo -e "${DGN}Using CPU Model: ${BGN}KVM64${CL}"
      CPU_TYPE=""
    fi
  else
    exit-script
  fi

  # Core Count
  if CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate CPU Cores" 8 58 4 --title "CORE COUNT" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$CORE_COUNT" ] || ! [[ "$CORE_COUNT" =~ ^[0-9]+$ ]]; then
      CORE_COUNT="4"
    fi
    echo -e "${DGN}Allocated Cores: ${BGN}$CORE_COUNT${CL}"
  else
    exit-script
  fi

  # RAM Size
  if RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate RAM in MiB" 8 58 4096 --title "RAM" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$RAM_SIZE" ] || ! [[ "$RAM_SIZE" =~ ^[0-9]+$ ]]; then
      RAM_SIZE="4096"
    fi
    echo -e "${DGN}Allocated RAM: ${BGN}$RAM_SIZE${CL}"
  else
    exit-script
  fi

  # Bridge
  if BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Bridge" 8 58 vmbr0 --title "BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$BRG" ]; then
      BRG="vmbr0"
    fi
    echo -e "${DGN}Using Bridge: ${BGN}$BRG${CL}"
  else
    exit-script
  fi

  # MAC Address
  if MAC1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a MAC Address" 8 58 "$GEN_MAC" --title "MAC ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$MAC1" ]; then
      MAC="$GEN_MAC"
    else
      MAC="$MAC1"
    fi
    echo -e "${DGN}Using MAC Address: ${BGN}$MAC${CL}"
  else
    exit-script
  fi

  # VLAN
  if VLAN1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a VLAN (leave blank for default)" 8 58 --title "VLAN" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$VLAN1" ]; then
      VLAN=""
      echo -e "${DGN}Using VLAN: ${BGN}Default${CL}"
    else
      if [[ "$VLAN1" =~ ^[0-9]+$ ]]; then
        VLAN=",tag=$VLAN1"
        echo -e "${DGN}Using VLAN: ${BGN}$VLAN1${CL}"
      else
        VLAN=""
        echo -e "${DGN}Invalid VLAN, using: ${BGN}Default${CL}"
      fi
    fi
  else
    exit-script
  fi

  # MTU
  if MTU1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Interface MTU Size (leave blank for default)" 8 58 --title "MTU SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$MTU1" ] || ! [[ "$MTU1" =~ ^[0-9]+$ ]]; then
      MTU=""
      echo -e "${DGN}Using Interface MTU Size: ${BGN}Default${CL}"
    else
      MTU=",mtu=$MTU1"
      echo -e "${DGN}Using Interface MTU Size: ${BGN}$MTU1${CL}"
    fi
  else
    exit-script
  fi

  # Start VM
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "START VIRTUAL MACHINE" --yesno "Start VM when completed?" 10 58); then
    echo -e "${DGN}Start VM when completed: ${BGN}yes${CL}"
    START_VM="yes"
  else
    echo -e "${DGN}Start VM when completed: ${BGN}no${CL}"
    START_VM="no"
  fi

  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "ADVANCED SETTINGS COMPLETE" --yesno "Ready to create HAOS $HAOS_VER VM?" --no-button Do-Over 10 58); then
    echo -e "${RD}Creating a HAOS VM using the above advanced settings${CL}"
  else
    header_info
    echo -e "${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

function start_script() {
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" --yesno "Use Default Settings?" --no-button Advanced 10 58); then
    header_info
    echo -e "${BL}Using Default Settings${CL}"
    default_settings
  else
    header_info
    echo -e "${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

# Main execution
check_root
arch_check
pve_check
ssh_check
start_script

msg_info "Validating Storage"
STORAGE_MENU=()
MSG_MAX_LENGTH=0
while read -r line; do
  TAG=$(echo "$line" | awk '{print $1}')
  TYPE=$(echo "$line" | awk '{printf "%-10s", $2}')
  FREE=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  fi
  STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content images | awk 'NR>1')

VALID=$(pvesm status -content images | awk 'NR>1')
if [ -z "$VALID" ]; then
  msg_error "Unable to detect a valid storage location."
  exit
elif [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  while [ -z "${STORAGE:+x}" ]; do
    if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID > /dev/null; then
      kill $SPINNER_PID > /dev/null 2>&1
    fi
    printf "\e[?25h"
    STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage Pools" --radiolist \
      "Which storage pool you would like to use for ${HN}?\nTo make a selection, use the Spacebar.\n" \
      16 $(($MSG_MAX_LENGTH + 23)) 6 \
      "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit
  done
fi
msg_ok "Using ${CL}${BL}$STORAGE${CL} ${GN}for Storage Location."
msg_ok "Virtual Machine ID is ${CL}${BL}$VMID${CL}."

msg_info "Retrieving the URL for Home Assistant ${HAOS_VER} Disk Image"
sleep 2
msg_ok "${CL}${BL}${HAOS_URL}${CL}"

msg_info "Downloading HAOS Disk Image"
if ! wget -q --show-progress -O "haos_ova-${HAOS_VER}.qcow2.xz" "$HAOS_URL"; then
  msg_error "Failed to download HAOS image"
  exit
fi
msg_ok "Downloaded ${CL}${BL}haos_ova-${HAOS_VER}.qcow2.xz${CL}"

msg_info "Extracting KVM Disk Image"
if ! unxz "haos_ova-${HAOS_VER}.qcow2.xz"; then
  msg_error "Failed to extract disk image"
  exit
fi
msg_ok "Extracted KVM Disk Image"

# Determine storage type and disk format
STORAGE_TYPE=$(pvesm status -storage "$STORAGE" | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
  nfs|dir|btrfs)
    DISK_IMPORT="-format raw"
    DISK_EXT=".raw"
    DISK_REF="$VMID/"
    THIN=""
    ;;
  local|local-lvm|local-zfs)
    DISK_IMPORT="-format raw"
    DISK_EXT=".raw"
    DISK_REF="$VMID/"
    THIN=""
    ;;
  *)
    DISK_IMPORT=""
    DISK_EXT=".qcow2"
    DISK_REF=""
    THIN="discard=on,ssd=1,"
    ;;
esac

# Set disk names
DISK0="vm-${VMID}-disk-0${DISK_EXT}"
DISK1="vm-${VMID}-disk-1${DISK_EXT}"
DISK0_REF="${STORAGE}:${DISK_REF}${DISK0}"
DISK1_REF="${STORAGE}:${DISK_REF}${DISK1}"

msg_info "Creating HAOS VM"
if ! qm create "$VMID" \
  -name "$HN" \
  -bios ovmf \
  -cores "$CORE_COUNT" \
  -memory "$RAM_SIZE" \
  -net0 "virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU" \
  -ostype l26 \
  -scsihw virtio-scsi-pci \
  -tags proxmox-helper-scripts \
  -onboot 1 \
  -agent 1 \
  -tablet 0 \
  -localtime 1 \
  ${MACHINE} ${CPU_TYPE}; then
  msg_error "Failed to create VM"
  exit
fi

# Allocate small disk for EFI
if ! pvesm alloc "$STORAGE" "$VMID" "$DISK0" 4M >/dev/null 2>&1; then
  msg_error "Failed to allocate EFI disk"
  exit
fi

# Import main disk
msg_info "Importing disk to storage"
if ! qm importdisk "$VMID" "haos_ova-${HAOS_VER}.qcow2" "$STORAGE" ${DISK_IMPORT} >/dev/null 2>&1; then
  msg_error "Failed to import disk"
  exit
fi

# Configure VM disks
msg_info "Configuring VM disks"
qm set "$VMID" \
  -efidisk0 "${DISK0_REF}${FORMAT}" \
  -scsi0 "${DISK1_REF},${DISK_CACHE}${THIN}size=32G" \
  -boot order=scsi0 \
  -description "<div align='center'><a href='https://Helper-Scripts.com' target='_blank' rel='noopener noreferrer'><img src='https://raw.githubusercontent.com/tteck/Proxmox/main/misc/images/logo-81x112.png'/></a>

# Home Assistant OS
Version: ${HAOS_VER}

<a href='https://ko-fi.com/D1D7EP4GF'><img src='https://img.shields.io/badge/&#x2615;-Buy me a coffee-blue' /></a>
</div>" >/dev/null

msg_ok "Created HAOS VM ${CL}${BL}(${HN})"

if [ "$START_VM" == "yes" ]; then
  msg_info "Starting Home Assistant OS VM"
  if qm start "$VMID"; then
    msg_ok "Started Home Assistant OS VM"
  else
    msg_error "Failed to start VM"
  fi
fi

msg_ok "Completed Successfully!\n"
echo -e "You can access Home Assistant at: ${BL}http://[VM_IP]:8123${CL}"
echo -e "Default username: ${BL}homeassistant${CL}"
echo -e "Default password: ${BL}Leave blank on first login${CL}"
