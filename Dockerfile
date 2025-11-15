FROM nvidia/cuda:13.0.2-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

# -----------------------------
# Install Base Dependencies
# -----------------------------
RUN apt-get update && apt-get install -y \
    software-properties-common \
    wget \
    git \
    curl \
    ca-certificates \
    ffmpeg \
    libssl-dev \
    libglib2.0-0 \
    libx264-dev \
    libx265-dev \
    python3 \
    python3-gi \
    python3-gi-cairo \
    gir1.2-gstreamer-1.0 \
    gir1.2-gst-plugins-base-1.0 \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------
# Install NVIDIA Video Codec SDK headers (required for hardware acceleration)
# -----------------------------
RUN apt-get update && apt-get install -y \
    build-essential \
    meson \
    ninja-build \
    pkg-config \
    git \
    && rm -rf /var/lib/apt/lists/* && \
    (apt-get update && apt-get install -y nv-codec-headers 2>/dev/null || \
     (git clone https://github.com/FFmpeg/nv-codec-headers.git /tmp/nv-codec-headers && \
      cd /tmp/nv-codec-headers && \
      make && make install && \
      rm -rf /tmp/nv-codec-headers)) && \
    rm -rf /var/lib/apt/lists/*

# -----------------------------
# Install WebKitGTK FIRST (required for webkitwebsrc plugin)
# WebKitGTK 2.46+ uses Skia and GPU acceleration by default
# -----------------------------
RUN apt-get update && apt-get install -y \
    libwebkit2gtk-4.0-37 \
    libwebkit2gtk-4.0-dev \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------
# Install GStreamer + Plugins (ALL packages first)
# -----------------------------
RUN apt-get update && apt-get install -y \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-nice \
    gstreamer1.0-gl \
    gstreamer1.0-x \
    gstreamer1.0-wpe \
    libgstrtspserver-1.0-dev \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libglib2.0-dev \
    liborc-0.4-dev \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------
# Build gst-plugins-bad from source with nvcodec support
# This enables nvh264dec and nvh264enc plugins for hardware acceleration
# IMPORTANT: Use Ubuntu source package to match GStreamer 1.20.3 version
# This ensures compatibility between GStreamer core and plugins
# We rely on h264parse config-interval=-1 for SPS/PPS insertion
# -----------------------------
RUN echo "deb-src http://archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb-src http://archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse" >> /etc/apt/sources.list && \
    apt-get update && apt-get install -y devscripts debhelper && \
    mkdir -p /tmp/gst-plugins-bad-source && \
    cd /tmp/gst-plugins-bad-source && \
    apt-get source gstreamer1.0-plugins-bad && \
    cd gst-plugins-bad1.0-* && \
    echo "Building nvcodec plugin from Ubuntu source (version: $(dpkg-parsechangelog -S Version))" && \
    meson setup build \
        -Dnvcodec=enabled \
        -Ddefault_library=shared \
        -Dprefix=/usr && \
    echo "=== Building nvcodec plugin ===" && \
    meson compile -C build 2>&1 | grep -i nvcodec || echo "Build output above" && \
    meson install -C build && \
    ldconfig && \
    cd / && \
    rm -rf /tmp/gst-plugins-bad-source && \
    apt-get purge -y devscripts debhelper && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

# Rebuild GStreamer registry to ensure all plugins are recognized
# Force a complete registry rebuild
RUN rm -rf /root/.cache/gstreamer-1.0/registry*.bin 2>/dev/null || true && \
    rm -rf ~/.cache/gstreamer-1.0/registry*.bin 2>/dev/null || true && \
    GST_PLUGIN_SYSTEM_PATH=/usr/lib/x86_64-linux-gnu/gstreamer-1.0 gst-inspect-1.0 >/dev/null 2>&1 && \
    gst-inspect-1.0 >/dev/null 2>&1 || true

# Verify GStreamer installation and check ALL required plugins
RUN gst-launch-1.0 --version && \
    echo "GStreamer installation verified" && \
    echo "=== Checking installed packages ===" && \
    dpkg -l | grep gstreamer | grep -E "(good|bad|wpe)" && \
    echo "=== Checking plugin directory ===" && \
    ls -la /usr/lib/x86_64-linux-gnu/gstreamer-1.0/ | grep -E "(tsdemux|webkit|nvcodec|wpe)" || echo "Plugins not found in standard location" && \
    echo "=== Checking nvcodec plugin dependencies ===" && \
    (ldd /usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstnvcodec.so 2>&1 | grep "not found" || echo "All dependencies satisfied") && \
    echo "=== Checking wpe plugin dependencies ===" && \
    (ldd /usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstwpe.so 2>&1 | grep "not found" || echo "All dependencies satisfied") && \
    echo "=== Listing all nvcodec elements ===" && \
    (gst-inspect-1.0 nvcodec 2>&1 || echo "nvcodec plugin not loadable") && \
    echo "=== Checking for nvcodec elements directly ===" && \
    (gst-inspect-1.0 | grep -i nv || echo "No nvcodec elements found") && \
    echo "=== Checking nvcodec plugin file ===" && \
    (strings /usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstnvcodec.so | grep -E "(nvh264|nvdec|nvenc)" | head -10 || echo "No nvcodec symbols found") && \
    echo "=== Listing all wpe elements ===" && \
    (gst-inspect-1.0 wpe 2>&1 | head -30 || echo "wpe plugin not loadable") && \
    echo "=== Checking ALL required pipeline elements ===" && \
    (gst-inspect-1.0 srtsrc >/dev/null 2>&1 && echo "✓ srtsrc: available" || echo "✗ srtsrc: NOT available") && \
    (gst-inspect-1.0 tsdemux >/dev/null 2>&1 && echo "✓ tsdemux: available" || echo "✗ tsdemux: NOT available") && \
    (gst-inspect-1.0 h264parse >/dev/null 2>&1 && echo "✓ h264parse: available" || echo "✗ h264parse: NOT available") && \
    (gst-inspect-1.0 avdec_h264 >/dev/null 2>&1 && echo "✓ avdec_h264: available (software decoder)" || echo "✗ avdec_h264: NOT available") && \
    (gst-inspect-1.0 nvh264dec >/dev/null 2>&1 && echo "✓ nvh264dec: available (GPU decoder)" || echo "✗ nvh264dec: NOT available") && \
    (gst-inspect-1.0 nvh264enc >/dev/null 2>&1 && echo "✓ nvh264enc: available (GPU encoder)" || echo "✗ nvh264enc: NOT available") && \
    (gst-inspect-1.0 x264enc >/dev/null 2>&1 && echo "✓ x264enc: available (software encoder fallback)" || echo "✗ x264enc: NOT available") && \
    (gst-inspect-1.0 wpesrc >/dev/null 2>&1 && echo "✓ wpesrc: available" || echo "✗ wpesrc: NOT available") && \
    (gst-inspect-1.0 compositor >/dev/null 2>&1 && echo "✓ compositor: available" || echo "✗ compositor: NOT available") && \
    (gst-inspect-1.0 videoconvert >/dev/null 2>&1 && echo "✓ videoconvert: available" || echo "✗ videoconvert: NOT available") && \
    (gst-inspect-1.0 mpegtsmux >/dev/null 2>&1 && echo "✓ mpegtsmux: available" || echo "✗ mpegtsmux: NOT available") && \
    (gst-inspect-1.0 srtsink >/dev/null 2>&1 && echo "✓ srtsink: available" || echo "✗ srtsink: NOT available") && \
    echo "=== Checking nvh264enc properties ===" && \
    (gst-inspect-1.0 nvh264enc 2>/dev/null | grep -E "(repeat-sequence-header|insert-sps-pps|gop-size|bitrate|preset)" | head -10 || echo "nvh264enc not available for property check") && \
    (gst-inspect-1.0 nvh264enc 2>/dev/null | grep -q "repeat-sequence-header" && echo "✓ repeat-sequence-header: AVAILABLE" || echo "✗ repeat-sequence-header: NOT available") && \
    echo "=== Checking h264parse properties ===" && \
    (gst-inspect-1.0 h264parse 2>/dev/null | grep -E "(config-interval|output-stream-format|insert-vui)" | head -10 || echo "h264parse not available for property check") && \
    echo "=== Plugin availability check complete ==="

# -----------------------------
# Set environment variables for GPU acceleration and stability
# -----------------------------
# Enable WebKitGTK GPU acceleration (WebKitGTK 2.46+ uses GPU by default)
ENV WEBKIT_DISABLE_COMPOSITING_MODE=0
ENV WEBKIT_ENABLE_GPU_PROCESS=1
# Enable GStreamer GL/GPU features
ENV GST_GL_PLATFORM=egl
ENV GST_GL_API=gles2
# Suppress warnings and improve stability
ENV GST_DEBUG_NO_COLOR=1
ENV XDG_RUNTIME_DIR=/tmp
ENV PULSE_RUNTIME_PATH=/tmp

# -----------------------------
# Create working directory
# -----------------------------
WORKDIR /app

# -----------------------------
# Copy pipeline scripts
# -----------------------------
COPY entrypoint.sh /app/entrypoint.sh
COPY gst_pipeline.py /app/gst_pipeline.py
RUN chmod +x /app/entrypoint.sh /app/gst_pipeline.py

# -----------------------------
# Health check
# -----------------------------
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD pgrep -f "gst-launch-1.0" > /dev/null || exit 1

# -----------------------------
# Default command
# -----------------------------
CMD ["/app/entrypoint.sh"]
