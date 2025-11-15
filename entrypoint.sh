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

# Determine encoder - MUST use GPU encoder (nvh264enc)
# GStreamer 1.20.3: nvh264enc does not have repeat-sequence-header property
# We rely on h264parse config-interval=-1 for SPS/PPS insertion
if check_plugin nvh264enc; then
    ENCODER="nvh264enc bitrate=6000 preset=low-latency-hq gop-size=30"
    echo "Using GPU encoder: nvh264enc"
else
    echo "ERROR: nvh264enc not available - GPU encoding required but not possible"
    exit 1
fi

# h264parse configuration for SPS/PPS insertion
# config-interval=-1 inserts SPS/PPS before every IDR frame
H264PARSE_OPTS="config-interval=-1"
echo "h264parse: $H264PARSE_OPTS"

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

# SRT source URIs - will cycle through these every 2 minutes
SRT_SOURCES=(
    "srt://172.18.0.4:6000/?mode=caller&transtype=live&streamid=708b95f3-2963-49c7-b765-c44ea37d9d4c,mode:request"
    "srt://172.18.0.4:6000/?mode=caller&transtype=live&streamid=a6128a3a-69cb-4da2-a654-1e5f7de4477f,mode:request"
    "srt://172.18.0.4:6000/?mode=caller&transtype=live&streamid=cd24154e-cede-45d9-b649-1f87adcbf2f0,mode:request"
    "srt://172.18.0.4:6000/?mode=caller&transtype=live&streamid=44e82d24-064e-4d22-bc84-3cbf2127bc19,mode:request"
)
SRT_SINK_URI="srt://172.18.0.4:6000?mode=caller&transtype=live&streamid=eeef12c8-6c83-42bf-b08f-e2e17b7c9f09.stream,mode:publish"
CURRENT_SOURCE_INDEX=0
SOURCE_SWITCH_INTERVAL=120  # 2 minutes in seconds

# Check if HTML overlay is available
USE_HTML_OVERLAY=false

get_current_source() {
    echo "${SRT_SOURCES[$CURRENT_SOURCE_INDEX]}"
}

switch_to_next_source() {
    CURRENT_SOURCE_INDEX=$(( (CURRENT_SOURCE_INDEX + 1) % ${#SRT_SOURCES[@]} ))
    echo "Switching to source $((CURRENT_SOURCE_INDEX + 1))/${#SRT_SOURCES[@]}: ${SRT_SOURCES[$CURRENT_SOURCE_INDEX]}"
}

run_pipeline() {
    local current_src=$(get_current_source)
    
    # Build pipeline directly - avoid string concatenation issues
    if [ "$USE_HTML_OVERLAY" = true ]; then
        # Pipeline with HTML overlay
        if [ -n "$AUDIO_ENCODER" ]; then
            # With HTML overlay + audio
            gst-launch-1.0 -v \
              srtsrc uri="${current_src}" '!' \
                tsdemux '!' h264parse '!' \
                ${DECODER} '!' \
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
                ${ENCODER} '!' \
                h264parse ${H264PARSE_OPTS} '!' \
                mpegtsmux name=mux '!' \
                srtsink uri="${SRT_SINK_URI}" \
              audiotestsrc wave=silence is-live=true '!' \
                audio/x-raw,rate=48000,channels=2 '!' \
                audioconvert '!' \
                ${AUDIO_ENCODER} '!' \
                mux.
        else
            # With HTML overlay, no audio
            gst-launch-1.0 -v \
              srtsrc uri="${current_src}" '!' \
                tsdemux '!' h264parse '!' \
                ${DECODER} '!' \
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
                ${ENCODER} '!' \
                h264parse ${H264PARSE_OPTS} '!' \
                mpegtsmux '!' \
                srtsink uri="${SRT_SINK_URI}"
        fi
    else
        # Pipeline without HTML overlay
        if [ -n "$AUDIO_ENCODER" ]; then
            # No HTML overlay + audio
            gst-launch-1.0 -v \
              srtsrc uri="${current_src}" '!' \
                tsdemux '!' h264parse '!' \
                ${DECODER} '!' \
                videoconvert '!' \
                video/x-raw,width=1920,height=1080 '!' \
                ${ENCODER} '!' \
                h264parse ${H264PARSE_OPTS} '!' \
                mpegtsmux name=mux '!' \
                srtsink uri="${SRT_SINK_URI}" \
              audiotestsrc wave=silence is-live=true '!' \
                audio/x-raw,rate=48000,channels=2 '!' \
                audioconvert '!' \
                ${AUDIO_ENCODER} '!' \
                mux.
        else
            # No HTML overlay, no audio
            gst-launch-1.0 -v \
              srtsrc uri="${current_src}" '!' \
                tsdemux '!' h264parse '!' \
                ${DECODER} '!' \
                videoconvert '!' \
                video/x-raw,width=1920,height=1080 '!' \
                ${ENCODER} '!' \
                h264parse ${H264PARSE_OPTS} '!' \
                mpegtsmux '!' \
                srtsink uri="${SRT_SINK_URI}"
        fi
    fi
}

# Run pipeline with source rotation every 2 minutes
# This function runs the pipeline and switches sources periodically
run_pipeline_with_rotation() {
    local pipeline_pid
    local start_time
    local elapsed_time
    
    while true; do
        start_time=$(date +%s)
        echo "Starting pipeline with source $((CURRENT_SOURCE_INDEX + 1))/${#SRT_SOURCES[@]}"
        echo "Source URI: $(get_current_source)"
        
        # Run pipeline in background and monitor it
        (
            run_pipeline
        ) &
        pipeline_pid=$!
        
        # Monitor pipeline and switch source after interval
        while kill -0 $pipeline_pid 2>/dev/null; do
            sleep 5
            elapsed_time=$(($(date +%s) - start_time))
            
            # Switch source after interval
            if [ $elapsed_time -ge $SOURCE_SWITCH_INTERVAL ]; then
                echo "Source switch interval reached (${SOURCE_SWITCH_INTERVAL}s), switching to next source..."
                kill $pipeline_pid 2>/dev/null
                wait $pipeline_pid 2>/dev/null
                switch_to_next_source
                break
            fi
        done
        
        # Wait for pipeline to exit (if it didn't exit due to source switch)
        wait $pipeline_pid 2>/dev/null
        EXIT_CODE=$?
        
        # If pipeline exited with error (not due to source switch), retry with backoff
        if [ $EXIT_CODE -ne 0 ] && [ $EXIT_CODE -ne 130 ] && [ $EXIT_CODE -ne 143 ]; then
            echo "Pipeline failed with exit code $EXIT_CODE, retrying in ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
        elif [ $EXIT_CODE -eq 0 ] || [ $EXIT_CODE -eq 130 ]; then
            # Normal exit or interrupted
            exit $EXIT_CODE
        fi
    done
}

# Start pipeline with source rotation
run_pipeline_with_rotation
