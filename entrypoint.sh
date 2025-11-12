#!/bin/bash
set -e

dbus-daemon --system &

Xorg -noreset +extension GLX +extension RANDR +extension RENDER -logfile /tmp/xorg.log -config /etc/X11/xorg.conf.d/10-dummy.conf :99 &

export DISPLAY=:99

sleep 5

x11vnc -display :99 -nopw -forever -shared &

pulseaudio --start

obs &

wait