#!/usr/bin/env python3
"""
Simple GStreamer pipeline with seamless source switching
- 4 SRT sources switching every 2 minutes
- GPU encoding/decoding
- Silent audio track
- TV test pattern fallback
- 1080p transparent PNG overlay (top layer)
"""

import gi
gi.require_version('Gst', '1.0')
from gi.repository import Gst, GLib
import sys
import os

Gst.init(None)

# Configuration
SRT_SOURCES = [
    "srt://172.18.0.4:6000/?mode=caller&transtype=live&streamid=708b95f3-2963-49c7-b765-c44ea37d9d4c,mode:request",
    "srt://172.18.0.4:6000/?mode=caller&transtype=live&streamid=a6128a3a-69cb-4da2-a654-1e5f7de4477f,mode:request",
    "srt://172.18.0.4:6000/?mode=caller&transtype=live&streamid=cd24154e-cede-45d9-b649-1f87adcbf2f0,mode:request",
    "srt://172.18.0.4:6000/?mode=caller&transtype=live&streamid=44e82d24-064e-4d22-bc84-3cbf2127bc19,mode:request",
]
SRT_SINK_URI = "srt://172.18.0.4:6000?mode=caller&transtype=live&streamid=eeef12c8-6c83-42bf-b08f-e2e17b7c9f09.stream,mode:publish"
SOURCE_SWITCH_INTERVAL = 120  # 2 minutes
USE_OVERLAY_IMAGE = os.environ.get('USE_OVERLAY_IMAGE', 'true').lower() == 'true'
PNG_OVERLAY_PATH = os.environ.get('PNG_OVERLAY_PATH', '/app/assets/logo.png')  # Path to 1080p transparent PNG

current_source_index = 0

def build_pipeline():
    """Build the GStreamer pipeline"""
    pipeline = Gst.Pipeline()
    
    # Create input-selector for seamless switching
    selector = Gst.ElementFactory.make("input-selector", "selector")
    pipeline.add(selector)
    
    # Add test pattern as fallback
    test_pattern = Gst.ElementFactory.make("videotestsrc", "test_pattern")
    test_pattern.set_property("pattern", 0)  # SMPTE color bars
    test_pattern.set_property("is-live", True)
    test_caps = Gst.ElementFactory.make("capsfilter", "test_caps")
    test_caps.set_property("caps", Gst.Caps.from_string("video/x-raw,width=1920,height=1080,framerate=30/1"))
    test_queue = Gst.ElementFactory.make("queue", "test_queue")
    
    for elem in [test_pattern, test_caps, test_queue]:
        pipeline.add(elem)
    test_pattern.link(test_caps)
    test_caps.link(test_queue)
    
    test_pad = selector.request_pad_simple("sink_%u")
    test_queue.get_static_pad("src").link(test_pad)
    
    # Add SRT sources
    source_elements = []
    for i, src_uri in enumerate(SRT_SOURCES):
        srtsrc = Gst.ElementFactory.make("srtsrc", f"srtsrc_{i}")
        tsdemux = Gst.ElementFactory.make("tsdemux", f"tsdemux_{i}")
        h264parse = Gst.ElementFactory.make("h264parse", f"h264parse_{i}")
        decoder = Gst.ElementFactory.make("nvh264dec", f"decoder_{i}")
        videoconvert = Gst.ElementFactory.make("videoconvert", f"videoconvert_{i}")
        queue = Gst.ElementFactory.make("queue", f"queue_{i}")
        
        srtsrc.set_property("uri", src_uri)
        h264parse.set_property("config-interval", -1)
        
        # Configure queue to be more resilient (leaky downstream, larger buffer)
        try:
            queue.set_property("max-size-time", 2000000000)  # 2 seconds in nanoseconds
            queue.set_property("leaky", "downstream")  # Drop old buffers if downstream is slow
        except Exception:
            pass  # Properties may not be available in all GStreamer versions
        
        for elem in [srtsrc, tsdemux, h264parse, decoder, videoconvert, queue]:
            pipeline.add(elem)
        
        srtsrc.link(tsdemux)
        
        def on_pad_added(demux, pad, parse_elem):
            caps = pad.get_current_caps()
            if caps and caps.get_structure(0).get_name().startswith('video/'):
                pad.link(parse_elem.get_static_pad("sink"))
        
        tsdemux.connect("pad-added", lambda d, p, pe=h264parse: on_pad_added(d, p, pe))
        h264parse.link(decoder)
        decoder.link(videoconvert)
        videoconvert.link(queue)
        
        sink_pad = selector.request_pad_simple("sink_%u")
        queue.get_static_pad("src").link(sink_pad)
        source_elements.append({'pad': sink_pad, 'srtsrc': srtsrc, 'queue': queue})
    
    # Encoding chain
    encoder = Gst.ElementFactory.make("nvh264enc", "encoder")
    encoder.set_property("bitrate", 6000)
    encoder.set_property("preset", "low-latency-hq")
    encoder.set_property("gop-size", 30)
    
    h264parse_out = Gst.ElementFactory.make("h264parse", "h264parse_out")
    h264parse_out.set_property("config-interval", -1)
    
    mpegtsmux = Gst.ElementFactory.make("mpegtsmux", "mux")
    srtsink = Gst.ElementFactory.make("srtsink", "srtsink")
    srtsink.set_property("uri", SRT_SINK_URI)
    srtsink.set_property("latency", 20000)
    
    # Audio
    audiotestsrc = Gst.ElementFactory.make("audiotestsrc", "audiotestsrc")
    audiotestsrc.set_property("wave", 4)  # silence
    audiotestsrc.set_property("is-live", True)
    audioconvert = Gst.ElementFactory.make("audioconvert", "audioconvert")
    audio_encoder = Gst.ElementFactory.make("avenc_aac", "audio_encoder")
    audio_encoder.set_property("bitrate", 128000)
    
    for elem in [encoder, h264parse_out, mpegtsmux, srtsink, audiotestsrc, audioconvert, audio_encoder]:
        pipeline.add(elem)
    
    # Link video chain with framerate conversion to 30fps and optional PNG overlay
    videorate = Gst.ElementFactory.make("videorate", "videorate")
    framerate_caps = Gst.ElementFactory.make("capsfilter", "framerate_caps")
    framerate_caps.set_property("caps", Gst.Caps.from_string("video/x-raw,width=1920,height=1080,framerate=30/1"))
    
    if not all([videorate, framerate_caps]):
        print("ERROR: Failed to create framerate conversion elements", flush=True)
        return None
    
    for elem in [videorate, framerate_caps]:
        pipeline.add(elem)
    
    selector.link(videorate)
    videorate.link(framerate_caps)
    
    # Check PNG overlay flag and file existence
    if USE_OVERLAY_IMAGE:
        overlay_dir = os.path.dirname(PNG_OVERLAY_PATH)
        if overlay_dir and not os.path.exists(overlay_dir):
            print(f"ERROR: USE_OVERLAY_IMAGE is enabled but directory does not exist: {overlay_dir}", flush=True)
            return None
        if not os.path.exists(PNG_OVERLAY_PATH):
            print(f"ERROR: USE_OVERLAY_IMAGE is enabled but file not found: {PNG_OVERLAY_PATH}", flush=True)
            return None
        if not os.path.isfile(PNG_OVERLAY_PATH):
            print(f"ERROR: USE_OVERLAY_IMAGE is enabled but path is not a file: {PNG_OVERLAY_PATH}", flush=True)
            return None
        if not os.access(PNG_OVERLAY_PATH, os.R_OK):
            print(f"ERROR: USE_OVERLAY_IMAGE is enabled but file is not readable: {PNG_OVERLAY_PATH}", flush=True)
            return None
        print(f"✓ PNG overlay file validated: {PNG_OVERLAY_PATH}", flush=True)
    
    if USE_OVERLAY_IMAGE:
        
        # Create compositor for PNG overlay
        compositor = Gst.ElementFactory.make("compositor", "compositor")
        compositor.set_property("background", "black")
        
        # PNG overlay source (top layer)
        filesrc = Gst.ElementFactory.make("filesrc", "png_filesrc")
        pngdec = Gst.ElementFactory.make("pngdec", "pngdec")
        imagefreeze = Gst.ElementFactory.make("imagefreeze", "imagefreeze")
        png_videoconvert = Gst.ElementFactory.make("videoconvert", "png_videoconvert")
        png_caps = Gst.ElementFactory.make("capsfilter", "png_caps")
        png_caps.set_property("caps", Gst.Caps.from_string("video/x-raw,format=BGRA,width=1920,height=1080,framerate=30/1"))
        png_queue = Gst.ElementFactory.make("queue", "png_queue")
        
        # Convert main video to BGRA format for compositor
        main_videoconvert = Gst.ElementFactory.make("videoconvert", "main_videoconvert")
        main_format_caps = Gst.ElementFactory.make("capsfilter", "main_format_caps")
        main_format_caps.set_property("caps", Gst.Caps.from_string("video/x-raw,format=BGRA,width=1920,height=1080,framerate=30/1"))
        main_queue = Gst.ElementFactory.make("queue", "main_queue")
        
        if not all([compositor, filesrc, pngdec, imagefreeze, png_videoconvert, png_caps, png_queue, main_videoconvert, main_format_caps, main_queue]):
            print("ERROR: Failed to create overlay elements", flush=True)
            return None
        
        filesrc.set_property("location", PNG_OVERLAY_PATH)
        imagefreeze.set_property("is-live", True)
        
        for elem in [compositor, filesrc, pngdec, imagefreeze, png_videoconvert, png_caps, png_queue, main_videoconvert, main_format_caps, main_queue]:
            pipeline.add(elem)
        
        # Link main video chain: framerate_caps → videoconvert → format_caps → queue → compositor sink_0
        framerate_caps.link(main_videoconvert)
        main_videoconvert.link(main_format_caps)
        main_format_caps.link(main_queue)
        
        # Link PNG overlay chain: filesrc → pngdec → imagefreeze → videoconvert → caps → queue → compositor sink_1
        filesrc.link(pngdec)
        pngdec.link(imagefreeze)
        imagefreeze.link(png_videoconvert)
        png_videoconvert.link(png_caps)
        png_caps.link(png_queue)
        
        # Connect to compositor using pad templates (fixes deprecation warnings)
        main_video_pad = main_queue.get_static_pad("src")
        comp_sink_0_template = compositor.get_pad_template("sink_%u")
        if comp_sink_0_template:
            comp_sink_0 = compositor.request_pad(comp_sink_0_template, None, None)
            if comp_sink_0:
                comp_sink_0.set_property("zorder", 0)
                main_video_pad.link(comp_sink_0)
        
        png_output_pad = png_queue.get_static_pad("src")
        comp_sink_1_template = compositor.get_pad_template("sink_%u")
        if comp_sink_1_template:
            comp_sink_1 = compositor.request_pad(comp_sink_1_template, None, None)
            if comp_sink_1:
                comp_sink_1.set_property("zorder", 1)  # Higher zorder = on top
                png_output_pad.link(comp_sink_1)
        
        # Compositor output → videoconvert → encoder
        comp_videoconvert = Gst.ElementFactory.make("videoconvert", "comp_videoconvert")
        comp_output_caps = Gst.ElementFactory.make("capsfilter", "comp_output_caps")
        comp_output_caps.set_property("caps", Gst.Caps.from_string("video/x-raw,width=1920,height=1080,framerate=30/1"))
        
        if not all([comp_videoconvert, comp_output_caps]):
            print("ERROR: Failed to create compositor output conversion elements", flush=True)
            return None
        
        for elem in [comp_videoconvert, comp_output_caps]:
            pipeline.add(elem)
        
        compositor.link(comp_videoconvert)
        comp_videoconvert.link(comp_output_caps)
        comp_output_caps.link(encoder)
    else:
        # Direct connection: framerate_caps → encoder (overlay disabled)
        framerate_caps.link(encoder)
    
    encoder.link(h264parse_out)
    
    # Get video pad using pad template
    video_template = mpegtsmux.get_pad_template("sink_%d")
    video_pad = mpegtsmux.request_pad(video_template, None, None)
    h264parse_out.get_static_pad("src").link(video_pad)
    
    # Link audio chain
    audiotestsrc.link_filtered(audioconvert, Gst.Caps.from_string("audio/x-raw,rate=48000,channels=2"))
    audioconvert.link(audio_encoder)
    
    # Get audio pad using pad template
    audio_template = mpegtsmux.get_pad_template("sink_%d")
    audio_pad = mpegtsmux.request_pad(audio_template, None, None)
    audio_encoder.get_static_pad("src").link(audio_pad)
    
    # Link muxer to sink
    mpegtsmux.get_static_pad("src").link(srtsink.get_static_pad("sink"))
    
    return pipeline, selector, source_elements, srtsink

def restart_source(source_elem):
    """Restart a stopped SRT source"""
    srtsrc = source_elem.get('srtsrc')
    if srtsrc:
        try:
            state_ret = srtsrc.get_state(Gst.CLOCK_TIME_NONE)
            if state_ret[0] == Gst.StateChangeReturn.SUCCESS:
                state = state_ret[1]
                # Restart if not already playing
                if state != Gst.State.PLAYING:
                    print(f"Restarting source {source_elem.get('index', 'unknown')} (current state: {state.value_nick})", flush=True)
                    srtsrc.set_state(Gst.State.NULL)  # Reset first
                    srtsrc.set_state(Gst.State.PLAYING)
                    return True
        except Exception as e:
            print(f"Failed to restart source {source_elem.get('index', 'unknown')}: {e}", flush=True)
    return False

def restart_all_sources(source_elements):
    """Restart all stopped sources"""
    restarted = 0
    for i, source_elem in enumerate(source_elements):
        source_elem['index'] = i + 1
        if restart_source(source_elem):
            restarted += 1
    if restarted > 0:
        print(f"Restarted {restarted} source(s)", flush=True)

def switch_source(selector, source_elements, next_index):
    """Switch to next source"""
    global current_source_index
    next_pad = source_elements[next_index]['pad']
    selector.set_property("active-pad", next_pad)
    current_source_index = next_index
    print(f"Switched to source {next_index + 1}/{len(SRT_SOURCES)}", flush=True)

def main():
    global current_source_index
    
    result = build_pipeline()
    if not result:
        print("ERROR: Failed to build pipeline", flush=True)
        sys.exit(1)
    
    pipeline, selector, source_elements, srtsink = result
    
    # Set initial source
    selector.set_property("active-pad", source_elements[0]['pad'])
    
    # Track sink connection state
    sink_connected = [False]  # Use list to allow modification in nested functions
    
    # Bus message handling
    bus = pipeline.get_bus()
    bus.add_signal_watch()
    loop = GLib.MainLoop()
    
    def on_message(bus, message):
        if message.type == Gst.MessageType.ERROR:
            err, debug = message.parse_error()
            element_name = message.src.get_name() if message.src else "unknown"
            error_msg = err.message.lower()
            
            # Handle SRT connection errors more gracefully
            # Note: During rolling updates, the new container starts while the old one is still running,
            # holding the SRT connection. The new container will retry until the old one stops and frees it.
            if 'srtsink' in element_name.lower() or 'srt' in element_name.lower():
                debug_lower = debug.lower() if debug else ""
                # Check for cascading data stream errors first (these are non-fatal)
                is_data_stream_error = (
                    'internal data stream error' in error_msg or 'streaming stopped' in debug_lower
                )
                if is_data_stream_error:
                    print(f"⚠ Data stream error from {element_name}: {err.message}", flush=True)
                    if debug:
                        print(f"Debug info: {debug}", flush=True)
                    print("This may be caused by downstream SRT connection issues. Pipeline will continue...", flush=True)
                    # Don't quit - these are often transient and resolve when SRT connects
                    return True
                
                # Check both error message and debug info for connection-related issues
                # These errors are expected during rolling updates when the old container holds the connection
                is_connection_error = (
                    'connection' in error_msg or 'does not exist' in error_msg or
                    'connection' in debug_lower or 'does not exist' in debug_lower or
                    'could not write' in error_msg or 'could not write' in debug_lower or
                    'failed to write' in error_msg or 'failed to write' in debug_lower or
                    'srt socket' in error_msg or 'srt socket' in debug_lower
                )
                if is_connection_error:
                    print(f"⚠ SRT connection error from {element_name}: {err.message}", flush=True)
                    if debug:
                        print(f"Debug info: {debug}", flush=True)
                    print(f"Hint: Ensure SRT listener is running at {SRT_SINK_URI}", flush=True)
                    print("Pipeline will continue running and retry connection...", flush=True)
                    # Don't quit on SRT connection errors - let it retry (important for rolling updates)
                    return True
                else:
                    print(f"ERROR from {element_name}: {err.message}", flush=True)
                    if debug:
                        print(f"Debug info: {debug}", flush=True)
                    loop.quit()
            # Handle cascading errors from upstream sources when downstream pipeline is in bad state
            # These often occur when SRT connection issues cause downstream elements to reject data
            elif 'imagefreeze' in element_name.lower() or 'srtsrc' in element_name.lower() or 'queue' in element_name.lower():
                debug_lower = debug.lower() if debug else ""
                # "Internal data stream error" often cascades from downstream connection issues
                if 'internal data stream error' in error_msg or 'streaming stopped' in debug_lower:
                    print(f"⚠ Data stream error from {element_name}: {err.message}", flush=True)
                    if debug:
                        print(f"Debug info: {debug}", flush=True)
                    print("This may be caused by downstream SRT connection issues. Pipeline will continue...", flush=True)
                    # Don't quit - these are often transient and resolve when SRT connects
                    return True
                else:
                    print(f"ERROR from {element_name}: {err.message}", flush=True)
                    if debug:
                        print(f"Debug info: {debug}", flush=True)
                    loop.quit()
            else:
                print(f"ERROR from {element_name}: {err.message}", flush=True)
                if debug:
                    print(f"Debug info: {debug}", flush=True)
                # If it's a filesrc error related to PNG overlay, provide helpful context
                if 'filesrc' in element_name.lower() or 'png' in element_name.lower():
                    print(f"Hint: Check if PNG overlay file exists and is readable: {PNG_OVERLAY_PATH}", flush=True)
                loop.quit()
        elif message.type == Gst.MessageType.WARNING:
            warn, debug = message.parse_warning()
            element_name = message.src.get_name() if message.src else "unknown"
            # Log SRT warnings but don't quit
            if 'srt' in element_name.lower():
                print(f"⚠ SRT warning from {element_name}: {warn.message}", flush=True)
        elif message.type == Gst.MessageType.STATE_CHANGED:
            if message.src == srtsink:
                old_state, new_state, pending_state = message.parse_state_changed()
                # Detect when sink transitions to PLAYING (connected)
                if new_state == Gst.State.PLAYING and not sink_connected[0]:
                    sink_connected[0] = True
                    print("✓ SRT sink connected - restarting sources...", flush=True)
                    restart_all_sources(source_elements)
                elif new_state != Gst.State.PLAYING and sink_connected[0]:
                    sink_connected[0] = False
                    print("⚠ SRT sink disconnected", flush=True)
        elif message.type == Gst.MessageType.INFO:
            info, debug = message.parse_info()
            element_name = message.src.get_name() if message.src else "unknown"
            # Log SRT connection info
            if 'srt' in element_name.lower() and ('connect' in info.message.lower() or 'connection' in info.message.lower()):
                print(f"ℹ SRT info from {element_name}: {info.message}", flush=True)
                # If sink connects, restart sources
                if 'srtsink' in element_name.lower() and 'connect' in info.message.lower():
                    if not sink_connected[0]:
                        sink_connected[0] = True
                        print("✓ SRT sink connected - restarting sources...", flush=True)
                        restart_all_sources(source_elements)
        return True
    
    bus.connect("message", on_message)
    
    # Start pipeline
    pipeline.set_state(Gst.State.PLAYING)
    print("Pipeline started", flush=True)
    
    # Source switching timer
    def switch_timer():
        next_index = (current_source_index + 1) % len(SRT_SOURCES)
        switch_source(selector, source_elements, next_index)
        return True
    
    GLib.timeout_add_seconds(SOURCE_SWITCH_INTERVAL, switch_timer)
    
    # Periodic recovery timer - check and restart stopped sources every 10 seconds
    # Only runs when sink is connected to avoid unnecessary checks
    def recovery_timer():
        if sink_connected[0]:
            restart_all_sources(source_elements)
        return True  # Keep timer running to check when sink connects
    
    GLib.timeout_add_seconds(10, recovery_timer)
    
    try:
        loop.run()
    finally:
        pipeline.set_state(Gst.State.NULL)

if __name__ == "__main__":
    main()
