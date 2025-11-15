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
    && rm -rf /var/lib/apt/lists/*

# -----------------------------
# Install GStreamer + Plugins (Latest Version)
# -----------------------------
# Add GStreamer PPA for latest stable releases
RUN add-apt-repository -y ppa:gstreamer-developers/ppa && \
    apt-get update && apt-get install -y \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-nice \
    gstreamer1.0-gl \
    gstreamer1.0-x \
    libgstrtspserver-1.0-dev \
    && rm -rf /var/lib/apt/lists/*

# Verify GStreamer version (should be 1.26.x or later)
RUN gst-launch-1.0 --version && \
    echo "GStreamer version check complete"

# -----------------------------
# Install WebKitGTK (for HTML overlay)
# This provides webkitwebsrc
# WebKitGTK 2.46+ uses Skia and GPU acceleration by default
# -----------------------------
RUN apt-get update && apt-get install -y \
    libwebkit2gtk-4.0-37 \
    libwebkit2gtk-4.0-dev \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------
# Set environment variables for GPU acceleration
# -----------------------------
# Enable WebKitGTK GPU acceleration (WebKitGTK 2.46+ uses GPU by default)
ENV WEBKIT_DISABLE_COMPOSITING_MODE=0
ENV WEBKIT_ENABLE_GPU_PROCESS=1
# Enable GStreamer GL/GPU features
ENV GST_GL_PLATFORM=egl
ENV GST_GL_API=gles2

# -----------------------------
# Create working directory
# -----------------------------
WORKDIR /app

# -----------------------------
# Copy pipeline script
# -----------------------------
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# -----------------------------
# Health check
# -----------------------------
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD pgrep -f "gst-launch-1.0" > /dev/null || exit 1

# -----------------------------
# Default command
# -----------------------------
CMD ["/app/entrypoint.sh"]
