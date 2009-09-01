/* Copyright 2009 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

using Gee;

extern void qsort(void *p, size_t num, size_t size, GLib.CompareFunc func);

//// Helper data structures ////

class Pair<G1, G2> : GLib.Object {
    public G1 first;
    public G2 second;
    
    public Pair(G1 object1, G2 object2) {
        first = object1;
        second = object2;
    }
}

class Stack<G> : GLib.Object {
    Gee.ArrayList<G> container;
    
    public Stack() {
        container = new Gee.ArrayList<G>();
    }
    
    public void push(G item) {
        container.add(item);
    }

    public G top() {
        assert(container.size > 0);
        return container.get(container.size - 1);
    }

    public void pop() {
        assert(container.size > 0);
        container.remove_at(container.size - 1);
    }
    
    public int size() {
        return container.size;
    }
}

//// GLib helper functions ////

bool dir_has_parent(string dir, string parent) {
    File new_path = File.new_for_path(dir);
    while (parent != new_path.get_path()) {
        new_path = new_path.get_parent();
        
        if (new_path == null)
            return false;
    }
    
    return true;
}

int compare_string(void *a, void *b) {
    char **a_string = a;
    char **b_string = b;
    
    return strcmp(*a_string, *b_string);
}

string? filename_to_uri(string filename) {
    try {
        return Filename.to_uri(filename);
    } catch (ConvertError e) { return null; }
}

void make_pipe(int fd, IOFunc func) throws IOChannelError {
    IOChannel pipe = new IOChannel.unix_new(fd);
    pipe.set_flags(IOFlags.NONBLOCK);
    pipe.add_watch(IOCondition.IN | IOCondition.HUP, func);
}

//// GTK helper functions ////

Gtk.TextIter get_insert_iter(Gtk.TextBuffer buffer) {
    Gtk.TextIter iter;
    buffer.get_iter_at_mark(out iter, buffer.get_insert());
    return iter;
}

void get_line_start_end(Gtk.TextIter iter, out Gtk.TextIter start, out Gtk.TextIter end) {
    start = iter;
    start.set_line_offset(0);
    end = iter;
    end.forward_line();
}

void append_with_tag(Gtk.TextBuffer buffer, string text, Gtk.TextTag? tag) {
    Gtk.TextIter end;
    buffer.get_end_iter(out end);
    if (tag != null)
        buffer.insert_with_tags(end, text, -1, tag);
    else
        buffer.insert(end, text, -1);
}

void append(Gtk.TextBuffer buffer, string text) {
    append_with_tag(buffer, text, null);
}

Gtk.TextIter iter_at_line_offset(Gtk.TextBuffer buffer, int line, int offset) {
    // We must be careful: TextBuffer.get_iter_at_line_offset() will crash if we give it an
    // offset greater than the length of the line.
    Gtk.TextIter iter;
    buffer.get_iter_at_line(out iter, line);
    int len = iter.get_chars_in_line() - 1;     // subtract 1 for \n
    if (len < 0)    // no \n was present, e.g. in an empty file
        len = 0;
    int end = int.min(len, offset);
    Gtk.TextIter ret;
    buffer.get_iter_at_line_offset(out ret, line, end);
    return ret;
}

weak string buffer_contents(Gtk.TextBuffer buffer) {
    Gtk.TextIter start;
    Gtk.TextIter end;
    buffer.get_bounds(out start, out end);
    return buffer.get_text(start, end, true);
}

Gtk.MenuItem get_menu_item(Gtk.UIManager manager, string path) {
    Gtk.MenuItem item = (Gtk.MenuItem) manager.get_widget(path);
    assert(item != null);
    return item;
}

//// Gedit helper functions ////

string? document_filename(Gedit.Document document) {
    string uri = document.get_uri();
    if (uri == null)
        return null;
    try {
        return Filename.from_uri(uri);
    } catch (ConvertError e) { return null; }
}

Gedit.Tab? find_tab(string filename, out Gedit.Window window) {
    string uri = filename_to_uri(filename);
    
    foreach (Gedit.Window w in Gedit.App.get_default().get_windows()) {
        Gedit.Tab tab = w.get_tab_from_uri(uri);
        if (tab != null) {
            window = w;
            return tab;
        }
    }
    return null;
}

