SOURCES = parser.vala scanner.vala valencia.vala

libvalencia.so: $(SOURCES)
	valac -X --shared -X -fPIC --vapidir=. --pkg gee-1.0 --pkg gedit-2.20 $^ -o $@

install:
	mkdir -p ~/.gnome2/gedit/plugins
	cp libvalencia.so valencia.gedit-plugin ~/.gnome2/gedit/plugins

parser: parser.vala scanner.vala
	valac --pkg gee-1.0 $^ -o $@

clean:
	rm -f $(SOURCES:.vala=.c) $(SOURCES:.vala=.h) *.so

