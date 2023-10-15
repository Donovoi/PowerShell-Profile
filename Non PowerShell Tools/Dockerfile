FROM debian:latest

# Install common packages
RUN apt-get update && apt-get install -y     git     curl     build-essential     x11-apps

# WSLg-specific settings
ENV DISPLAY=:0
VOLUME /mnt/wslg/.X11-unix:/tmp/.X11-unix
