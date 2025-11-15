#!/bin/bash
# Don't exit on errors - we want to retry on connection failures
set +e

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

# Check if a property exists for an element
check_property() {
    local element=$1
    local property=$2
    # gst-inspect outputs properties with format: "  property-name     : Description"
    # Match property name followed by whitespace and colon
    gst-inspect-1.0 "$element" 2>/dev/null | grep -qE "^\s+$property\s+:" || return 1
    return 0
}

# Determine encoder (prefer GPU, fallback to CPU)
# Based on GStreamer docs: nvh264enc has repeat-sequence-header property
# Per GStreamer docs: repeat-sequence-header=true inserts SPS/PPS before each IDR frame
if check_plugin nvh264enc; then
    ENCODER="nvh264enc bitrate=6000 preset=low-latency-hq"
    # Check for repeat-sequence-header property (nvh264enc supports this per GStreamer docs)
    if check_property nvh264enc repeat-sequence-header; then
        ENCODER="$ENCODER repeat-sequence-header=true"
        echo "nvh264enc: using repeat-sequence-header=true to insert SPS/PPS before each IDR frame"
    else
        echo "WARNING: nvh264enc repeat-sequence-header property not found"
        # Try aud property to ensure Access Unit Delimiters (may help with parameter sets)
        if check_property nvh264enc aud; then
            ENCODER="$ENCODER aud=true"
            echo "nvh264enc: using aud=true to ensure Access Unit Delimiters"
        fi
        echo "Note: Relying on h264parse config-interval=-1 to insert SPS/PPS with every IDR frame"
    fi
    # Set keyframe interval (gop-size or keyframe-interval)
    if check_property nvh264enc gop-size; then
        ENCODER="$ENCODER gop-size=30"
    elif check_property nvh264enc keyframe-interval; then
        ENCODER="$ENCODER keyframe-interval=30"
    fi
    echo "Using GPU encoder: nvh264enc with options: $ENCODER"
else
    # x264enc: key-int-max is documented property for keyframe interval
    ENCODER="x264enc bitrate=6000 speed-preset=ultrafast tune=zerolatency key-int-max=30"
    echo "Using CPU encoder: x264enc"
fi

# Determine h264parse options
# According to GStreamer docs: config-interval=-1 inserts SPS/PPS before every IDR frame
# There was a bug with config-interval not working for byte-stream format, but it should be fixed in 1.20.x
# We'll use both config-interval and ensure stream-format is set correctly
H264PARSE_OPTS=""
if check_property h264parse config-interval; then
    H264PARSE_OPTS="config-interval=-1"
    echo "h264parse: using config-interval=-1 to insert SPS/PPS with every IDR frame (per GStreamer docs)"
else
    # Fallback: check if property exists with different matching
    if gst-inspect-1.0 h264parse 2>/dev/null | grep -q "config-interval"; then
        H264PARSE_OPTS="config-interval=-1"
        echo "h264parse: using config-interval=-1 (fallback detection)"
    else
        echo "WARNING: h264parse config-interval property not found - checking available properties..."
        gst-inspect-1.0 h264parse 2>/dev/null | grep -E "(config|interval|sps|pps)" | head -5 || true
    fi
fi
# Keep byte-stream format for compatibility with mpegtsmux
# Note: There was a bug with config-interval not working for byte-stream, but it should be fixed in 1.20.x
# If issues persist, the encoder should output SPS/PPS initially, and h264parse will re-insert them
if check_property h264parse output-format; then
    H264PARSE_OPTS="$H264PARSE_OPTS output-format=byte-stream"
    echo "h264parse: using output-format=byte-stream (required for mpegtsmux compatibility)"
fi
echo "h264parse options: ${H264PARSE_OPTS:-none}"

# Determine audio encoder (prefer aacenc, fallback to avenc_aac)
if check_plugin aacenc; then
    AUDIO_ENCODER="aacenc bitrate=128000"
    echo "Using aacenc for audio"
elif check_plugin avenc_aac; then
    AUDIO_ENCODER="avenc_aac bitrate=128000"
    echo "Using avenc_aac for audio"
else
    AUDIO_ENCODER=""
    echo "No AAC encoder available - skipping audio track"
fi

# Build and execute pipeline with retry logic for connection failures
# Retry indefinitely with exponential backoff (capped at 30s)
RETRY_DELAY=2
MAX_DELAY=30

run_pipeline() {
    if check_plugin wpesrc; then
        echo "Using wpesrc for HTML overlay"
        # Pipeline with webkit overlay
        if [ -n "$AUDIO_ENCODER" ]; then
            # Pipeline with audio track
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
                h264parse${H264PARSE_OPTS:+ $H264PARSE_OPTS} '!' \
                mpegtsmux name=mux '!' \
                srtsink uri=srt://172.18.0.4:6000?mode=caller\&transtype=live\&streamid=eeef12c8-6c83-42bf-b08f-e2e17b7c9f09.stream,mode:publish \
              audiotestsrc wave=silence is-live=true '!' \
                audio/x-raw,rate=48000,channels=2 '!' \
                audioconvert '!' \
                $AUDIO_ENCODER '!' \
                mux.
        else
            # Pipeline without audio track
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
                h264parse${H264PARSE_OPTS:+ $H264PARSE_OPTS} '!' \
                mpegtsmux '!' \
                srtsink uri=srt://172.18.0.4:6000?mode=caller\&transtype=live\&streamid=eeef12c8-6c83-42bf-b08f-e2e17b7c9f09.stream,mode:publish
        fi
    else
        echo "wpesrc not available - skipping HTML overlay, using SRT pass-through"
        # Pipeline without webkit overlay (just pass through SRT stream)
        if [ -n "$AUDIO_ENCODER" ]; then
            # Pipeline with audio track
            gst-launch-1.0 -v \
              srtsrc uri=srt://172.18.0.4:6000/?mode=caller\&transtype=live\&streamid=a6128a3a-69cb-4da2-a654-1e5f7de4477f,mode:request '!' \
                tsdemux '!' h264parse '!' \
                $DECODER '!' \
                videoconvert '!' \
                video/x-raw,width=1920,height=1080 '!' \
                $ENCODER '!' \
                h264parse${H264PARSE_OPTS:+ $H264PARSE_OPTS} '!' \
                mpegtsmux name=mux '!' \
                srtsink uri=srt://172.18.0.4:6000?mode=caller\&transtype=live\&streamid=eeef12c8-6c83-42bf-b08f-e2e17b7c9f09.stream,mode:publish \
              audiotestsrc wave=silence is-live=true '!' \
                audio/x-raw,rate=48000,channels=2 '!' \
                audioconvert '!' \
                $AUDIO_ENCODER '!' \
                mux.
        else
            # Pipeline without audio track
            gst-launch-1.0 -v \
              srtsrc uri=srt://172.18.0.4:6000/?mode=caller\&transtype=live\&streamid=a6128a3a-69cb-4da2-a654-1e5f7de4477f,mode:request '!' \
                tsdemux '!' h264parse '!' \
                $DECODER '!' \
                videoconvert '!' \
                video/x-raw,width=1920,height=1080 '!' \
                $ENCODER '!' \
                h264parse${H264PARSE_OPTS:+ $H264PARSE_OPTS} '!' \
                mpegtsmux '!' \
                srtsink uri=srt://172.18.0.4:6000?mode=caller\&transtype=live\&streamid=eeef12c8-6c83-42bf-b08f-e2e17b7c9f09.stream,mode:publish
        fi
    fi
}

# Run pipeline with retry logic - retry indefinitely to keep container healthy
RETRY_COUNT=0
CURRENT_DELAY=$RETRY_DELAY
while true; do
    if [ $RETRY_COUNT -gt 0 ]; then
        echo "Pipeline failed, retrying in ${CURRENT_DELAY}s (attempt $((RETRY_COUNT + 1)))..."
        sleep $CURRENT_DELAY
        # Exponential backoff, capped at MAX_DELAY
        CURRENT_DELAY=$((CURRENT_DELAY * 2))
        if [ $CURRENT_DELAY -gt $MAX_DELAY ]; then
            CURRENT_DELAY=$MAX_DELAY
        fi
    fi
    
    run_pipeline
    EXIT_CODE=$?
    
    # If pipeline exits with 0 or 130 (interrupted), exit normally
    if [ $EXIT_CODE -eq 0 ] || [ $EXIT_CODE -eq 130 ]; then
        exit $EXIT_CODE
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
done
