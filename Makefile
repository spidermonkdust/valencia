PLUGIN = valencia

# The version number appears here and also in valencia.gedit-plugin.
VERSION = 0.3.0+trunk

VALAC = valac

SOURCES = autocomplete.vala browser.vala expression.vala gtk_util.vala parser.vala program.vala \
          scanner.vala settings.vala util.vala valencia.vala
 
PACKAGES = --pkg gedit-2.20 --pkg gee-1.0 --pkg gtk+-2.0 --pkg vala-0.10 --pkg vte

PACKAGE_VERSIONS = \
    gedit-2.20 >= 2.24.0 \
    gee-1.0 >= 0.1.3 \
    gtk+-2.0 >= 2.14.4 \
    vala-0.10 >= 0.9.5 \
    vte >= 0.17.4

OUTPUTS = libvalencia.so valencia.gedit-plugin

DIST_FILES = $(SOURCES) \
             Makefile \
             gedit-2.20.deps gedit-2.20.vapi valencia.png \
             valencia.gedit-plugin valencia.gedit-plugin.m4 \
             AUTHORS COPYING INSTALL NEWS README THANKS
DIST_TAR = $(PLUGIN)-$(VERSION).tar
DIST_TAR_BZ2 = $(DIST_TAR).bz2
DIST_TAR_GZ = $(DIST_TAR).gz

ICON_DIR = ~/.local/share/icons/hicolor/128x128/apps

all: valencia.gedit-plugin libvalencia.so
	

valencia.gedit-plugin: valencia.gedit-plugin.m4 Makefile
	m4 -DVERSION='$(VERSION)' valencia.gedit-plugin.m4 > valencia.gedit-plugin

libvalencia.so: $(SOURCES) Makefile
	@ pkg-config --print-errors --exists '$(PACKAGE_VERSIONS)'
	$(VALAC) $(VFLAGS) -X --shared -X -fPIC --vapidir=. $(PACKAGES) $(SOURCES) -o $@

install: libvalencia.so valencia.gedit-plugin
	@ [ `whoami` != "root" ] || ( echo 'Run make install as yourself, not as root.' ; exit 1 )
	mkdir -p ~/.gnome2/gedit/plugins
	cp $(OUTPUTS) ~/.gnome2/gedit/plugins
	mkdir -p $(ICON_DIR)
	cp -p valencia.png $(ICON_DIR)

uninstall:
	rm -f $(foreach o, $(OUTPUTS), ~/.gnome2/gedit/plugins/$o)
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
	rm -f valencia.gedit-plugin

