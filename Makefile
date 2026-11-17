CC = clang
ARCH = -arch arm64 -arch x86_64
VERSION ?= $(shell tr -d '[:space:]' < VERSION)
CFLAGS = -fobjc-arc -O2 -mmacosx-version-min=12.0 -DSL4_VERSION=\"$(VERSION)\"
# make plugin DEBUG=1 builds the driver with its streaming diagnostics and its debug commands
# (tools/latency/bin/sl4dbg: test hooks); make install DEBUG=1 also installs it
PLUGIN_DEFS = $(if $(DEBUG),-DSL4_DEBUG=1)

all: plugin api panel dump flash controlpanel

plugin:
	$(CC) $(ARCH) -bundle $(CFLAGS) $(PLUGIN_DEFS) -Iplugin -framework Foundation -framework CoreAudio -framework IOKit -framework IOUSBHost plugin/SL4Device.m -o SL4Device

# build the driver and install it into the installed driver bundle, then restart coreaudiod
# (tools/install-sl4.sh; asks for your password). The release package must be installed first.
# make install DEBUG=1 installs a debug build; make install puts a release build back.
install: plugin
	sudo tools/install-sl4.sh

api:
	$(CC) $(ARCH) -dynamiclib $(CFLAGS) -install_name /Library/Frameworks/SL4Api.framework/Versions/A/SL4Api -current_version $(VERSION) -compatibility_version 1.0.0 -framework Foundation -framework CoreAudio -framework IOKit -Iplugin tools/SL4Api.m -o SL4Api

panel:
	$(CC) $(ARCH) $(CFLAGS) -framework Foundation -framework CoreAudio -framework IOKit -Itools -Iplugin tools/sl4panel.m tools/SL4Passthrough.m -o sl4panel

dump:
	$(CC) $(ARCH) $(CFLAGS) -Itools -Iplugin -framework Foundation -framework CoreAudio -framework IOKit -framework IOUSBHost tools/sl4dump.m tools/SL4Passthrough.m -o sl4dump

flash:
	$(CC) $(ARCH) $(CFLAGS) -Itools -Iplugin -framework Foundation -framework CoreAudio -framework IOKit -framework IOUSBHost tools/firmware/sl4flash.m tools/SL4Passthrough.m -o sl4flash

# SL 4 Control Panel.app (SwiftUI, universal), in the repository root
controlpanel:
	tools/controlpanel/build-app.sh

# the installer package and download zip, built into build/ (VERSION=x.y.z, default from VERSION)
package:
	Installer/build-pkg.sh $(VERSION)

# sl4apitest: checks SL4Api as Serato DJ Pro 2.5.5 uses it (run the x86_64 slice with arch -x86_64)
apitest:
	$(CC) $(ARCH) -O2 tools/sl4apitest.c -o sl4apitest

# latency and glitch test tools (tools/latency/README.md), built into tools/latency/bin
LATENCY_TOOLS = rtlat sinetest chtone chrec devprobe setrate sl4dbg volctl meters
latency: $(addprefix tools/latency/bin/,$(LATENCY_TOOLS))

tools/latency/bin/%: tools/latency/%.c tools/latency/common.h
	@mkdir -p tools/latency/bin
	$(CC) -O2 -framework CoreAudio -framework CoreFoundation -framework AudioToolbox $< -o $@

# the hardware tests in one run (tools/hwtest.sh), on the installed driver with a box attached
# (install a debug build first, make install DEBUG=1, to also run the debug-only tests):
#   make hwtest ARGS="--loopback"   with the loopback cable in (Deck 1 Out L to Deck 1 In L); add
#                                   --no-physical to skip the steps that need someone at the box
#                                   (the box's rate control, sleep, unplug and replug)
hwtest: panel apitest latency
	tools/hwtest.sh $(ARGS)

clean:
	rm -f SL4Device SL4Api sl4panel sl4apitest sl4dump sl4flash
	rm -rf tools/latency/bin "SL 4 Control Panel.app" build

.PHONY: all plugin install api panel dump flash controlpanel package apitest latency hwtest clean
