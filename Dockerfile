FROM nvidia/cuda:13.0.2-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Ljubljana

# RUN sed -i 's/security.ubuntu.com/mirrors.ustc.edu.cn/g' /etc/apt/sources.list
# RUN sed -i 's/archive.ubuntu.com/mirrors.ustc.edu.cn/g' /etc/apt/sources.list

RUN apt-get update &&\
    apt-get install -y software-properties-common curl gnupg && \
    add-apt-repository ppa:obsproject/obs-studio -y && \
    apt-get install -y --no-install-recommends \
    vlc \
    obs-studio \
    libsrt1.4-openssl \
    wget \
    dbus \
    mesa-utils \
    x11-xserver-utils \
    xserver-xorg-video-dummy \
    xserver-xorg-core \
    xinit \
    libgl1-mesa-glx \
    libgl1-mesa-dri \
    libnvidia-egl-wayland1 \
    obs-studio \
    pulseaudio \
    dbus-x11 \
    x11vnc \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/X11/xorg.conf.d
RUN echo 'Section "Device"\n    Identifier "DummyDevice"\n    Driver "dummy"\n    VideoRam 256000\nEndSection\n\nSection "Monitor"\n    Identifier "DummyMonitor"\n    HorizSync 28.0-80.0\n    VertRefresh 48.0-75.0\nEndSection\n\nSection "Screen"\n    Identifier "DummyScreen"\n    Device "DummyDevice"\n    Monitor "DummyMonitor"\n    DefaultDepth 24\n    SubSection "Display"\n        Depth 24\n        Modes "1920x1080"\n    EndSubSection\nEndSection\n' > /etc/X11/xorg.conf.d/10-dummy.conf

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,video,utility,graphics
ENV OBS_USE_EGL=1

RUN useradd -m obsuser

COPY entrypoint.sh /home/obsuser/entrypoint.sh
RUN chmod +x /home/obsuser/entrypoint.sh \
    && chown obsuser:obsuser /home/obsuser/entrypoint.sh

WORKDIR /home/obsuser

ENTRYPOINT ["/home/obsuser/entrypoint.sh"]