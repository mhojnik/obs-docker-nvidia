#!/bin/bash
set -e

# Disable history expansion to allow ! in GStreamer pipeline
set +H
shopt -u histexpand 2>/dev/null || true

# Rebuild GStreamer registry at runtime to ensure all plugins are found
rm -rf /root/.cache/gstreamer-1.0/registry*.bin 2>/dev/null || true
rm -rf ~/.cache/gstreamer-1.0/registry*.bin 2>/dev/null || true
export GST_PLUGIN_SYSTEM_PATH=/usr/lib/x86_64-linux-gnu/gstreamer-1.0:/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0
gst-inspect-1.0 >/dev/null 2>&1 || true

# Check which plugins are available
check_plugin() {
    gst-inspect-1.0 "$1" >/dev/null 2>&1
}

# Determine decoder (prefer GPU, fallback to CPU)
if check_plugin nvh264dec; then
    DECODER="nvh264dec"
    echo "Using GPU decoder: nvh264dec"
else
    DECODER="avdec_h264"
    echo "Using CPU decoder: avdec_h264"
fi

# Determine encoder (prefer GPU, fallback to CPU)
if check_plugin nvh264enc; then
    ENCODER="nvh264enc bitrate=6000 preset=low-latency-hq"
    echo "Using GPU encoder: nvh264enc"
else
    ENCODER="x264enc bitrate=6000 speed-preset=ultrafast tune=zerolatency"
    echo "Using CPU encoder: x264enc"
fi

# Build and execute pipeline - check if wpesrc is available (wpe plugin provides wpesrc/wpevideosrc, not webkitwebsrc)
if check_plugin wpesrc; then
    echo "Using wpesrc for HTML overlay"
    # Pipeline with webkit overlay
    gst-launch-1.0 -v \
      srtsrc uri=srt://172.18.0.4:6000/?mode=caller\&transtype=live\&streamid=a6128a3a-69cb-4da2-a654-1e5f7de4477f,mode:request '!' \
        tsdemux '!' h264parse '!' \
        $DECODER '!' \
        videoconvert '!' \
        video/x-raw,format=BGRA,width=1920,height=1080 '!' \
        queue '!' comp.sink_0 \
      wpesrc location=https://index.hr '!' \
        video/x-raw,format=BGRA,width=1280,height=720,framerate=30/1 '!' \
        queue '!' comp.sink_1 \
      compositor name=comp sink_0::zorder=0 sink_1::zorder=1 \
        background=black '!' \
        video/x-raw,width=1920,height=1080 '!' \
        videoconvert '!' \
        $ENCODER '!' \
        h264parse '!' mpegtsmux '!' \
        srtsink uri=srt://172.18.0.4:6000?mode=caller\&transtype=live\&streamid=eeef12c8-6c83-42bf-b08f-e2e17b7c9f09.stream,mode:publish
else
    echo "webkitwebsrc not available - skipping HTML overlay, using SRT pass-through"
    # Pipeline without webkit overlay (just pass through SRT stream)
    gst-launch-1.0 -v \
      srtsrc uri=srt://172.18.0.4:6000/?mode=caller\&transtype=live\&streamid=a6128a3a-69cb-4da2-a654-1e5f7de4477f,mode:request '!' \
        tsdemux '!' h264parse '!' \
        $DECODER '!' \
        videoconvert '!' \
        video/x-raw,width=1920,height=1080 '!' \
        $ENCODER '!' \
        h264parse '!' mpegtsmux '!' \
        srtsink uri=srt://172.18.0.4:6000?mode=caller\&transtype=live\&streamid=eeef12c8-6c83-42bf-b08f-e2e17b7c9f09.stream,mode:publish
fi
