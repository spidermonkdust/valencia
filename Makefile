SOURCES = parser.vala scanner.vala valencia.vala

libvalencia.so: $(SOURCES)
	valac -X --shared -X -fPIC --vapidir=. --pkg gedit-2.20 --pkg vala-1.0 $^ -o $@

install:
	mkdir -p ~/.gnome2/gedit/plugins
	cp libvalencia.so valencia.gedit-plugin ~/.gnome2/gedit/plugins

clean:
	rm -f $(SOURCES:.vala=.c) $(SOURCES:.vala=.h) *.so

