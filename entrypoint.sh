#!/bin/bash
set -e

# GPU-accelerated pipeline
# Using nvh264dec for GPU-accelerated H.264 decoding (outputs NV12)
# Using nvvidconv for GPU-accelerated format conversion
# Using videoconvert for final format conversion to BGRA (compositor requirement)
# WebKitGTK GPU acceleration enabled via environment variables
gst-launch-1.0 -v \
  srtsrc uri=srt://172.18.0.4:6000/?mode=caller&transtype=live&streamid=a6128a3a-69cb-4da2-a654-1e5f7de4477f,mode:request ! \
    tsdemux ! h264parse ! \
    nvh264dec ! \
    nvvidconv ! \
    video/x-raw,format=NV12,width=1920,height=1080 ! \
    videoconvert ! \
    video/x-raw,format=BGRA,width=1920,height=1080 ! \
    queue ! comp.sink_0 \
  webkitwebsrc location=https://index.hr ! \
    video/x-raw,format=BGRA,width=1280,height=720,framerate=30/1 ! \
    queue ! comp.sink_1 \
  compositor name=comp sink_0::zorder=0 sink_1::zorder=1 \
    background=black ! \
    video/x-raw,width=1920,height=1080 ! \
    videoconvert ! \
    nvvidconv ! \
    nvh264enc bitrate=6000 preset=low-latency-hq ! \
    h264parse ! mpegtsmux ! \
    srtsink uri=srt://172.18.0.4:6000?mode=caller&transtype=live&streamid=eeef12c8-6c83-42bf-b08f-e2e17b7c9f09.stream,mode:publish
