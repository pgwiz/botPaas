#!/usr/bin/env bash
set -e

echo "=== Linux Swap Setup (Persistent) ==="
echo

# Root check
if [[ $EUID -ne 0 ]]; then
  echo "❌ Please run as root (use sudo)"
  exit 1
fi

# Check if swap already exists
if swapon --show | grep -q "/swapfile"; then
  echo "⚠️  Swapfile already exists at /swapfile"
  swapon --show
  echo "Aborting to avoid overwriting existing swap."
  exit 1
fi

# Get available disk space on /
AVAILABLE_GB=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')

echo "Available disk space on / : ${AVAILABLE_GB} GB"
echo

# Ask user for desired swap size
read -rp "Enter desired swap size in GB (recommended ≤ ${AVAILABLE_GB}): " SWAP_GB

# Validate input
if ! [[ "$SWAP_GB" =~ ^[0-9]+$ ]]; then
  echo "❌ Invalid input. Please enter a number."
  exit 1
fi

if (( SWAP_GB <= 0 )); then
  echo "❌ Swap size must be greater than 0."
  exit 1
fi

if (( SWAP_GB >= AVAILABLE_GB )); then
  echo "❌ Not enough disk space. Choose less than ${AVAILABLE_GB} GB."
  exit 1
fi

echo
echo "Creating ${SWAP_GB} GB swapfile..."
echo

# Create swapfile
fallocate -l "${SWAP_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB * 1024)) status=progress

chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

# Persist swap
grep -qE '^\s*/swapfile\s+' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Tune swappiness
sysctl vm.swappiness=10
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf

echo
echo "✅ Swap setup complete!"
echo
swapon --show
free -h
