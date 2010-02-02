PLUGIN = valencia
VERSION = 0.2.1

VALAC = valac

SOURCES = autocomplete.vala browser.vala expression.vala gtk_util.vala parser.vala program.vala \
          scanner.vala settings.vala util.vala valencia.vala
 
PACKAGES = --pkg gedit-2.20 --pkg gee-1.0 --pkg gtk+-2.0 --pkg vala-1.0 --pkg vte

PACKAGE_VERSIONS = \
    gedit-2.20 >= 2.24.0 \
    gee-1.0 >= 0.1.3 \
    gtk+-2.0 >= 2.14.4 \
    vala-1.0 >= 0.7.10 \
    vte >= 0.17.4

OUTPUTS = libvalencia.so valencia.gedit-plugin

DIST_FILES = $(SOURCES) \
             Makefile \
             gedit-2.20.deps gedit-2.20.vapi valencia.gedit-plugin \
             AUTHORS COPYING INSTALL NEWS README THANKS
DIST_TAR = $(PLUGIN)-$(VERSION).tar
DIST_TAR_BZ2 = $(DIST_TAR).bz2

libvalencia.so: $(SOURCES)
	@ pkg-config --print-errors --exists '$(PACKAGE_VERSIONS)'
	$(VALAC) $(VFLAGS) -X --shared -X -fPIC --vapidir=. $(PACKAGES) $^ -o $@

install: libvalencia.so
	@ [ `whoami` != "root" ] || ( echo 'Run make install as yourself, not as root.' ; exit 1 )
	mkdir -p ~/.gnome2/gedit/plugins
	cp $(OUTPUTS) ~/.gnome2/gedit/plugins

uninstall:
	rm -f $(foreach o, $(OUTPUTS), ~/.gnome2/gedit/plugins/$o)

parser:  expression.vala parser.vala program.vala scanner.vala util.vala
	$(VALAC) $(VFLAGS) --pkg vala-1.0 --pkg gtk+-2.0 $^ -o $@

$(DIST_TAR_BZ2): $(DIST_FILES)
	tar -cv $(DIST_FILES) > $(DIST_TAR)
	bzip2 $(DIST_TAR)

dist: $(DIST_TAR_BZ2)

clean:
	rm -f $(SOURCES:.vala=.c) $(SOURCES:.vala=.h) *.so

