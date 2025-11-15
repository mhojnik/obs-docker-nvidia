#!/bin/bash
# Simple entrypoint - all pipeline logic is in Python script

# Disable history expansion to allow ! in GStreamer pipeline
set +H
shopt -u histexpand 2>/dev/null || true

# Rebuild GStreamer registry at runtime to ensure all plugins are found
rm -rf /root/.cache/gstreamer-1.0/registry*.bin 2>/dev/null || true
rm -rf ~/.cache/gstreamer-1.0/registry*.bin 2>/dev/null || true
export GST_PLUGIN_SYSTEM_PATH=/usr/lib/x86_64-linux-gnu/gstreamer-1.0:/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0
gst-inspect-1.0 >/dev/null 2>&1 || true

# Run Python pipeline script (handles all pipeline logic)
python3 /app/gst_pipeline.py
