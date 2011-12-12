PLUGIN = valencia

# The version number appears here and also in valencia.plugin.
VERSION = 0.3.0+trunk

VALAC = valac

SOURCES = autocomplete.vala browser.vala expression.vala gtk_util.vala parser.vala program.vala \
          scanner.vala settings.vala util.vala valencia.vala
 
PACKAGES = --pkg gedit --pkg gee-1.0 --pkg gtk+-3.0 --pkg gtksourceview-3.0 \
           --pkg libpeas-1.0 --pkg libvala-0.16 --pkg vte-2.90

PACKAGE_VERSIONS = \
    gedit >= 2.91.0 \
    gee-1.0 >= 0.1.3 \
    gtksourceview-3.0 >= 3.0.0 \
    gtk+-3.0 >= 3.0.0 \
    libvala-0.16 >= 0.15.0 \
    vte-2.90 >= 0.27.90

OUTPUTS = libvalencia.so valencia.plugin

DIST_FILES = $(SOURCES) \
             Makefile \
             valencia.png \
             valencia.plugin valencia.plugin.m4 \
             AUTHORS COPYING INSTALL NEWS README THANKS
DIST_TAR = $(PLUGIN)-$(VERSION).tar
DIST_TAR_BZ2 = $(DIST_TAR).bz2
DIST_TAR_GZ = $(DIST_TAR).gz

ICON_DIR = ~/.local/share/icons/hicolor/128x128/apps

all: valencia.plugin libvalencia.so

valencia.plugin: valencia.plugin.m4 Makefile
	@ type m4 > /dev/null || ( echo 'm4 is missing and is required to build Valencia. ' ; exit 1 )
	m4 -DVERSION='$(VERSION)' valencia.plugin.m4 > valencia.plugin

libvalencia.so: $(SOURCES) Makefile
	@ pkg-config --print-errors --exists '$(PACKAGE_VERSIONS)'
	$(VALAC) $(VFLAGS) -X --shared -X -fPIC $(PACKAGES) $(SOURCES) -o $@

install: libvalencia.so valencia.plugin
	@ [ `whoami` != "root" ] || ( echo 'Run make install as yourself, not as root.' ; exit 1 )
	mkdir -p ~/.local/share/gedit/plugins
	cp $(OUTPUTS) ~/.local/share/gedit/plugins
	mkdir -p $(ICON_DIR)
	cp -p valencia.png $(ICON_DIR)

uninstall:
	rm -f $(foreach o, $(OUTPUTS), ~/.local/share/gedit/plugins/$o)
	rm -f $(ICON_DIR)/valencia.png

parser:  expression.vala parser.vala program.vala scanner.vala util.vala
	$(VALAC) $(VFLAGS) --pkg vala-1.0 --pkg gtk+-2.0 $^ -o $@

dist: $(DIST_FILES)
	mkdir -p $(PLUGIN)-$(VERSION)
	cp --parents $(DIST_FILES) $(PLUGIN)-$(VERSION)
	tar --bzip2 -cvf $(DIST_TAR_BZ2) $(PLUGIN)-$(VERSION)
	tar --gzip -cvf $(DIST_TAR_GZ) $(PLUGIN)-$(VERSION)
	rm -rf $(PLUGIN)-$(VERSION)

clean:
	rm -f $(SOURCES:.vala=.c) $(SOURCES:.vala=.h) *.so
	rm -f valencia.plugin

