libvalencia.so: valencia.vala
	valac -C --vapidir=. --pkg gedit-2.20 --pkg vala-1.0 valencia.vala
	gcc --shared -fPIC -o libvalencia.so `pkg-config --cflags --libs gedit-2.20 vala-1.0` valencia.c

install:
	mkdir -p ~/.gnome2/gedit/plugins
	cp libvalencia.so valencia.gedit-plugin ~/.gnome2/gedit/plugins

clean:
	rm -f valencia.[ch] *.so

