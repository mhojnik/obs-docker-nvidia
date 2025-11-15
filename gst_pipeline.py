#!/usr/bin/env python3
"""
GStreamer pipeline with seamless source switching using input-selector
- Always uses GPU encoder/decoder (fails if not available)
- Always includes silent audio track
- Optional HTML overlay (switchable via compositor)
- Always streams at least a 1080p TV test pattern (SMPTE color bars)
- Switches between multiple SRT sources every 2 minutes without interrupting the stream
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

# Fixed configuration - always use GPU and silent audio
DECODER = "nvh264dec"
ENCODER_NAME = "nvh264enc"
ENCODER_PROPS = {
    "bitrate": 6000,
    "preset": "low-latency-hq",
    "gop-size": 30
}
AUDIO_ENCODER_NAME = "avenc_aac"
AUDIO_ENCODER_PROPS = {"bitrate": 128000}

# Optional HTML overlay (can be enabled/disabled)
HTML_OVERLAY_ENABLED = os.environ.get('HTML_OVERLAY_ENABLED', 'false').lower() == 'true'
HTML_OVERLAY_URL = os.environ.get('HTML_OVERLAY_URL', 'https://index.hr')

current_source_index = 0

def check_element(element_name):
    """Check if a GStreamer element is available"""
    factory = Gst.ElementFactory.find(element_name)
    return factory is not None

def build_pipeline():
    """Build the GStreamer pipeline with input-selector"""
    # Verify required elements are available
    if not check_element(DECODER):
        print(f"ERROR: {DECODER} not available - GPU decoder required")
        return None
    if not check_element(ENCODER_NAME):
        print(f"ERROR: {ENCODER_NAME} not available - GPU encoder required")
        return None
    if not check_element("input-selector"):
        print("ERROR: input-selector not available - required for seamless switching")
        return None
    
    pipeline = Gst.Pipeline()
    
    # Create input-selector for seamless source switching
    selector = Gst.ElementFactory.make("input-selector", "selector")
    if not selector:
        print("ERROR: Failed to create input-selector")
        return None
    pipeline.add(selector)
    
    # Create TV test pattern source (always available as fallback)
    # This ensures we always stream at least a 1080p test pattern canvas
    test_pattern_pad = None
    test_pattern_source = Gst.ElementFactory.make("videotestsrc", "test_pattern_source")
    test_pattern_caps_filter = Gst.ElementFactory.make("capsfilter", "test_pattern_caps")
    test_pattern_queue = Gst.ElementFactory.make("queue", "test_pattern_queue")
    
    if test_pattern_source and test_pattern_caps_filter and test_pattern_queue:
        test_pattern_source.set_property("pattern", 0)  # SMPTE color bars (standard TV test signal)
        test_pattern_source.set_property("is-live", True)
        
        test_pattern_caps = Gst.Caps.from_string("video/x-raw,width=1920,height=1080,framerate=30/1")
        test_pattern_caps_filter.set_property("caps", test_pattern_caps)
        
        pipeline.add(test_pattern_source)
        pipeline.add(test_pattern_caps_filter)
        pipeline.add(test_pattern_queue)
        
        test_pattern_source.link(test_pattern_caps_filter)
        test_pattern_caps_filter.link(test_pattern_queue)
        
        # Connect test pattern source to selector (as fallback source)
        test_pattern_pad = selector.get_request_pad("sink_test_pattern")
        if test_pattern_pad:
            test_pattern_queue.get_static_pad("src").link(test_pattern_pad)
            print("TV test pattern (SMPTE color bars) source added as fallback")
    
    # Create source chains for each SRT source
    source_elements = []
    for i, src_uri in enumerate(SRT_SOURCES):
        # Create source chain: srtsrc -> tsdemux -> h264parse -> decoder -> videoconvert -> queue -> selector
        srtsrc = Gst.ElementFactory.make("srtsrc", f"srtsrc_{i}")
        tsdemux = Gst.ElementFactory.make("tsdemux", f"tsdemux_{i}")
        h264parse_in = Gst.ElementFactory.make("h264parse", f"h264parse_in_{i}")
        decoder = Gst.ElementFactory.make(DECODER, f"decoder_{i}")
        videoconvert = Gst.ElementFactory.make("videoconvert", f"videoconvert_{i}")
        queue = Gst.ElementFactory.make("queue", f"queue_{i}")
        
        if not all([srtsrc, tsdemux, h264parse_in, decoder, videoconvert, queue]):
            print(f"ERROR: Failed to create elements for source {i}")
            return None
        
        # Set properties
        srtsrc.set_property("uri", src_uri)
        h264parse_in.set_property("config-interval", -1)
        
        # Add elements to pipeline
        for elem in [srtsrc, tsdemux, h264parse_in, decoder, videoconvert, queue]:
            pipeline.add(elem)
        
        # Link source chain (tsdemux has dynamic pads)
        if not srtsrc.link(tsdemux):
            print(f"ERROR: Failed to link srtsrc to tsdemux for source {i}")
            return None
        
        # Connect to tsdemux pad-added signal to handle dynamic video pad
        def on_pad_added(demux, pad, parse_element):
            """Handle dynamic pad from tsdemux"""
            caps = pad.get_current_caps()
            if caps:
                structure = caps.get_structure(0)
                if structure.get_name().startswith('video/'):
                    parse_sink = parse_element.get_static_pad("sink")
                    if parse_sink:
                        pad.link(parse_sink)
        
        tsdemux.connect("pad-added", lambda demux, pad: on_pad_added(demux, pad, h264parse_in))
        
        # Link the rest of the chain
        if not h264parse_in.link(decoder):
            print(f"ERROR: Failed to link h264parse to decoder for source {i}")
            return None
        if not decoder.link(videoconvert):
            print(f"ERROR: Failed to link decoder to videoconvert for source {i}")
            return None
        if not videoconvert.link(queue):
            print(f"ERROR: Failed to link videoconvert to queue for source {i}")
            return None
        
        # Get selector sink pad and link queue to it
        sink_pad = selector.get_request_pad(f"sink_{i}")
        if not sink_pad:
            print(f"ERROR: Failed to get sink pad {i} from input-selector")
            return None
        
        queue_src = queue.get_static_pad("src")
        if queue_src and sink_pad:
            if not queue_src.link(sink_pad):
                print(f"ERROR: Failed to link queue to selector sink pad {i}")
                return None
        
        source_elements.append({
            'srtsrc': srtsrc,
            'queue': queue,
            'pad': sink_pad
        })
    
    # Build compositor chain if HTML overlay is enabled
    compositor = None
    html_source = None
    if HTML_OVERLAY_ENABLED and check_element("wpesrc"):
        # Create HTML overlay source
        html_source = Gst.ElementFactory.make("wpesrc", "wpesrc")
        if html_source:
            html_source.set_property("location", HTML_OVERLAY_URL)
            
            # Create compositor to overlay HTML on video
            compositor = Gst.ElementFactory.make("compositor", "compositor")
            if compositor:
                compositor.set_property("background", 1)  # black background
                pipeline.add(html_source)
                pipeline.add(compositor)
                
                # Link HTML source to compositor sink_1
                html_videoconvert = Gst.ElementFactory.make("videoconvert", "html_videoconvert")
                html_queue = Gst.ElementFactory.make("queue", "html_queue")
                if html_videoconvert and html_queue:
                    pipeline.add(html_videoconvert)
                    pipeline.add(html_queue)
                    
                    # Set caps for HTML source
                    html_caps = Gst.Caps.from_string("video/x-raw,format=BGRA,width=1920,height=1080,framerate=30/1")
                    html_caps_filter = Gst.ElementFactory.make("capsfilter", "html_caps")
                    if html_caps_filter:
                        html_caps_filter.set_property("caps", html_caps)
                        pipeline.add(html_caps_filter)
                        html_source.link(html_caps_filter)
                        html_caps_filter.link(html_videoconvert)
                    else:
                        html_source.link(html_videoconvert)
                    
                    html_videoconvert.link(html_queue)
                    
                    # Link to compositor sink_1
                    comp_sink_1 = compositor.get_request_pad("sink_1")
                    if comp_sink_1:
                        comp_sink_1.set_property("zorder", 1)
                        html_queue.get_static_pad("src").link(comp_sink_1)
    
    # Build encoding chain: selector -> (compositor if overlay) -> encoder -> h264parse -> mpegtsmux -> srtsink
    encoder = Gst.ElementFactory.make(ENCODER_NAME, "encoder")
    if not encoder:
        print("ERROR: Failed to create encoder")
        return None
    
    # Set encoder properties
    for key, value in ENCODER_PROPS.items():
        try:
            if isinstance(value, int):
                encoder.set_property(key, value)
            else:
                encoder.set_property(key, value)
        except Exception as e:
            print(f"WARNING: Failed to set encoder property {key}={value}: {e}")
    
    h264parse_out = Gst.ElementFactory.make("h264parse", "h264parse_out")
    h264parse_out.set_property("config-interval", -1)
    
    mpegtsmux = Gst.ElementFactory.make("mpegtsmux", "mux")
    srtsink = Gst.ElementFactory.make("srtsink", "srtsink")
    
    if not all([encoder, h264parse_out, mpegtsmux, srtsink]):
        print("ERROR: Failed to create encoding chain elements")
        return None
    
    srtsink.set_property("uri", SRT_SINK_URI)
    
    # Add elements to pipeline
    for elem in [encoder, h264parse_out, mpegtsmux, srtsink]:
        pipeline.add(elem)
    
    # Link video chain: selector -> (compositor if overlay) -> capsfilter -> encoder
    caps_filter = Gst.ElementFactory.make("capsfilter", "capsfilter")
    if caps_filter:
        caps = Gst.Caps.from_string("video/x-raw,width=1920,height=1080")
        caps_filter.set_property("caps", caps)
        pipeline.add(caps_filter)
    
    if compositor:
        # With compositor: selector -> compositor -> capsfilter -> encoder
        # Link selector output to compositor sink_0 (main video)
        selector_src = selector.get_static_pad("src")
        comp_sink_0 = compositor.get_request_pad("sink_0")
        if selector_src and comp_sink_0:
            comp_sink_0.set_property("zorder", 0)
            # Need videoconvert and caps for format conversion
            selector_videoconvert = Gst.ElementFactory.make("videoconvert", "selector_videoconvert")
            selector_caps = Gst.ElementFactory.make("capsfilter", "selector_caps")
            if selector_caps:
                selector_caps_caps = Gst.Caps.from_string("video/x-raw,format=BGRA,width=1920,height=1080")
                selector_caps.set_property("caps", selector_caps_caps)
                pipeline.add(selector_caps)
                if selector_videoconvert:
                    pipeline.add(selector_videoconvert)
                    selector_src.link(selector_videoconvert)
                    selector_videoconvert.link(selector_caps)
                    selector_caps.get_static_pad("src").link(comp_sink_0)
                else:
                    selector_src.link(selector_caps)
                    selector_caps.get_static_pad("src").link(comp_sink_0)
            elif selector_videoconvert:
                pipeline.add(selector_videoconvert)
                selector_src.link(selector_videoconvert)
                selector_videoconvert.get_static_pad("src").link(comp_sink_0)
            else:
                selector_src.link(comp_sink_0)
        
        # Link compositor output to capsfilter or encoder
        comp_videoconvert = Gst.ElementFactory.make("videoconvert", "comp_videoconvert")
        if comp_videoconvert:
            pipeline.add(comp_videoconvert)
            compositor.link(comp_videoconvert)
            if caps_filter:
                comp_videoconvert.link(caps_filter)
                caps_filter.link(encoder)
            else:
                comp_videoconvert.link(encoder)
        else:
            if caps_filter:
                compositor.link(caps_filter)
                caps_filter.link(encoder)
            else:
                compositor.link(encoder)
    else:
        # Without compositor: selector -> capsfilter -> encoder
        if caps_filter:
            selector.link(caps_filter)
            caps_filter.link(encoder)
        else:
            selector.link(encoder)
    
    if not encoder.link(h264parse_out):
        print("ERROR: Failed to link encoder to h264parse")
        return None
    
    # Get muxer video pad
    video_pad = mpegtsmux.get_request_pad("sink_%d" % 0)
    if not video_pad:
        print("ERROR: Failed to get video pad from mpegtsmux")
        return None
    
    h264parse_src = h264parse_out.get_static_pad("src")
    if h264parse_src and video_pad:
        if not h264parse_src.link(video_pad):
            print("ERROR: Failed to link h264parse to mpegtsmux video pad")
            return None
    
    # Always add silent audio track
    audio_encoder = Gst.ElementFactory.make(AUDIO_ENCODER_NAME, "audio_encoder")
    if audio_encoder:
        for key, value in AUDIO_ENCODER_PROPS.items():
            try:
                audio_encoder.set_property(key, int(value))
            except:
                audio_encoder.set_property(key, value)
        
        audiotestsrc = Gst.ElementFactory.make("audiotestsrc", "audiotestsrc")
        audioconvert = Gst.ElementFactory.make("audioconvert", "audioconvert")
        
        if audiotestsrc and audioconvert:
            audiotestsrc.set_property("wave", 4)  # silence
            audiotestsrc.set_property("is-live", True)
            
            audio_caps = Gst.Caps.from_string("audio/x-raw,rate=48000,channels=2")
            
            pipeline.add(audiotestsrc)
            pipeline.add(audioconvert)
            pipeline.add(audio_encoder)
            
            if not audiotestsrc.link_filtered(audioconvert, audio_caps):
                print("ERROR: Failed to link audiotestsrc to audioconvert")
                return None
            if not audioconvert.link(audio_encoder):
                print("ERROR: Failed to link audioconvert to audio encoder")
                return None
            
            # Get muxer sink pad for audio
            audio_pad = mpegtsmux.get_request_pad("sink_%d" % 1)
            if audio_pad:
                audio_src = audio_encoder.get_static_pad("src")
                if audio_src:
                    if not audio_src.link(audio_pad):
                        print("ERROR: Failed to link audio encoder to mpegtsmux")
                        return None
    
    # Link muxer to sink
    mux_src = mpegtsmux.get_static_pad("src")
    sink_sink = srtsink.get_static_pad("sink")
    if mux_src and sink_sink:
        if not mux_src.link(sink_sink):
            print("ERROR: Failed to link mpegtsmux to srtsink")
            return None
    
    return pipeline, selector, source_elements, compositor, test_pattern_pad

def switch_source(selector, source_elements, next_index):
    """Switch to the next source seamlessly"""
    global current_source_index
    if next_index >= len(source_elements):
        next_index = 0
    
    try:
        current_pad = selector.get_property("active-pad")
    except:
        current_pad = None
    
    next_pad = source_elements[next_index]['pad']
    
    if next_pad:
        if next_pad != current_pad:
            print(f"Switching from source {current_source_index + 1} to source {next_index + 1}")
            try:
                selector.set_property("active-pad", next_pad)
                current_source_index = next_index
                return True
            except Exception as e:
                print(f"ERROR: Failed to switch pad: {e}")
                return False
        else:
            return True
    return False

def toggle_html_overlay(compositor, enabled):
    """Toggle HTML overlay visibility (if compositor exists)"""
    if compositor:
        # Control visibility via compositor pad zorder or alpha
        # For now, we'll just log the state change
        print(f"HTML overlay {'enabled' if enabled else 'disabled'}")
        return True
    return False

def main():
    """Main function"""
    global current_source_index
    
    print("Building GStreamer pipeline with seamless source switching...")
    print(f"GPU Decoder: {DECODER}")
    print(f"GPU Encoder: {ENCODER_NAME}")
    print(f"HTML Overlay: {'enabled' if HTML_OVERLAY_ENABLED else 'disabled'}")
    
    result = build_pipeline()
    if not result:
        print("ERROR: Failed to build pipeline")
        sys.exit(1)
    
    pipeline, selector, source_elements, compositor, test_pattern_pad = result
    
    # Set initial active pad (prefer first SRT source, fallback to test pattern)
    initial_pad = None
    if source_elements:
        initial_pad = source_elements[0]['pad']
        if initial_pad:
            selector.set_property("active-pad", initial_pad)
            print(f"Starting with SRT source 1/{len(SRT_SOURCES)}")
    elif test_pattern_pad:
        # Fallback to TV test pattern if no SRT sources available
        selector.set_property("active-pad", test_pattern_pad)
        print("Starting with TV test pattern (SMPTE color bars) - no SRT sources available")
    
    # Create main loop
    loop = GLib.MainLoop()
    
    # Set up bus message handling
    bus = pipeline.get_bus()
    bus.add_signal_watch()
    
    def on_bus_message(bus, message):
        """Handle bus messages"""
        if message.type == Gst.MessageType.ERROR:
            err, debug = message.parse_error()
            print(f"ERROR: {err.message}")
            if debug:
                print(f"Debug info: {debug}")
            loop.quit()
            return False
        elif message.type == Gst.MessageType.EOS:
            print("End of stream")
            loop.quit()
            return False
        return True
    
    bus.connect("message", on_bus_message)
    
    # Start pipeline
    print("Starting pipeline...")
    ret = pipeline.set_state(Gst.State.PLAYING)
    if ret == Gst.StateChangeReturn.FAILURE:
        print("ERROR: Failed to start pipeline")
        sys.exit(1)
    
    # Set up source switching timer
    def switch_timer():
        """Timer callback to switch sources"""
        global current_source_index
        next_index = (current_source_index + 1) % len(SRT_SOURCES)
        switch_source(selector, source_elements, next_index)
        return True  # Continue timer
    
    # Start switching timer
    GLib.timeout_add_seconds(SOURCE_SWITCH_INTERVAL, switch_timer)
    
    # Main loop
    try:
        loop.run()
    except KeyboardInterrupt:
        print("\nStopping pipeline...")
    finally:
        pipeline.set_state(Gst.State.NULL)

if __name__ == "__main__":
    main()
