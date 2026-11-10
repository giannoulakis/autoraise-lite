override CXXFLAGS += -O2 -Wall -fobjc-arc -D"NS_FORMAT_ARGUMENT(A)="
APP := AutoRaiseLite.app
LABEL := io.github.giannoulakis.autoraise-lite
AGENT := $(HOME)/Library/LaunchAgents/$(LABEL).plist

.PHONY: all clean install uninstall

all: $(APP)

clean:
	rm -rf AutoRaiseLite $(APP)

AutoRaiseLite: AutoRaise.mm
	clang++ $(CXXFLAGS) -o $@ $^ -framework AppKit

# Ad hoc signed: macOS asks for Accessibility again whenever the binary changes
$(APP): AutoRaiseLite Info.plist AutoRaise.icns
	rm -rf $@
	mkdir -p $@/Contents/MacOS $@/Contents/Resources
	cp AutoRaiseLite $@/Contents/MacOS/
	cp Info.plist $@/Contents/
	cp AutoRaise.icns $@/Contents/Resources/
	codesign --force --sign - $@

install: $(APP)
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	cp $(LABEL).plist $(AGENT)
	launchctl bootstrap gui/$$(id -u) $(AGENT)

uninstall:
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	rm -f $(AGENT)
	rm -rf /Applications/$(APP)
