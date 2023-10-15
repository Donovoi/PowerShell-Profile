#!/bin/bash

# Step 1: Check KVM and Install Packages
echo "Installing packages for KVM..."
sudo apt -y install bridge-utils cpu-checker libvirt-clients libvirt-daemon qemu qemu-kvm

# Step 2: Additional Packages from Initial Setup
echo "Installing additional packages..."
sudo apt install -y qemu qemu-kvm libvirt-clients libvirt-daemon-system bridge-utils virt-manager libguestfs-tools

# Step 3: X11 and WSLg Packages
echo "Installing x11-apps..."
sudo apt install -y x11-apps

# Step 4: Create Dockerfile
echo "Creating Dockerfile..."

# Generate the Dockerfile with WSLg-specific settings hardcoded
cat <<EOL > Dockerfile
FROM debian:latest

# Install common packages
RUN apt-get update && apt-get install -y \
    git \
    curl \
    build-essential \
    x11-apps

# WSLg-specific settings
ENV DISPLAY=${DISPLAY:-:0.0}
VOLUME /mnt/wslg/.X11-unix:/tmp/.X11-unix
EOL

# Step 5: Docker Build
echo "Building Docker image..."
docker build -t dockerosxwsl2 .

# Step 6: Run Container with WSLg settings
echo "Running Docker container..."
docker run -e "DISPLAY=${DISPLAY:-:0.0}" -v /mnt/wslg/.X11-unix:/tmp/.X11-unix dockerosxwsl2

echo "Script completed."
