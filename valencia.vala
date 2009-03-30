using Gee;

struct Position {
    public int line;        // line number, starting from 1
    public int character;   // character in line, starting from 1
    
    public Position(int line, int character) {
        this.line = line;
        this.character = character;
    }
}

void make_pipe(int fd, IOFunc func) throws IOChannelError {
    IOChannel pipe = new IOChannel.unix_new(fd);
    pipe.set_flags(IOFlags.NONBLOCK);
    pipe.add_watch(IOCondition.IN | IOCondition.HUP, func);
}

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

void select_line(Gtk.TextBuffer buffer, int line) {
    Gtk.TextIter iter;
    buffer.get_iter_at_line(out iter, line - 1);
    Gtk.TextIter start;
    Gtk.TextIter end;
    get_line_start_end(iter, out start, out end);
    buffer.select_range(start, end);
}

Gtk.TextIter iter_at_position(Gtk.TextBuffer buffer, Position pos) {
    // We must be careful: get_iter_at_line_offset() will crash if we give it an
    // offset greater than the length of the line.
    Gtk.TextIter iter;
    buffer.get_iter_at_line(out iter, pos.line - 1);
    int len = iter.get_chars_in_line() - 1;     // subtract 1 for \n
    int end = int.min(len, pos.character - 1);
    Gtk.TextIter ret;
    buffer.get_iter_at_line_offset(out ret, pos.line - 1, end);
    return ret;
}

void select_range(Gtk.TextBuffer buffer, Position start_pos, Position end_pos) {
    buffer.select_range(iter_at_position(buffer, start_pos),
                        iter_at_position(buffer, end_pos));
}

string? document_filename(Gedit.Document document) {
    string uri = document.get_uri();
    if (uri == null)
        return null;
    try {
        return Filename.from_uri(uri);
    } catch (ConvertError e) { return null; }
}

// Navigate to the given file and ensure that the given line is visible.
// If the file is not already open in gedit, open it in the given window.
Gedit.Tab? navigate(Gedit.Window window, string filename, int line, out bool is_new) {
    string uri;
    try {
        uri = Filename.to_uri(filename);
    } catch (ConvertError e) { return null; }
    foreach (Gedit.Window w in Gedit.App.get_default().get_windows()) {
        Gedit.Tab tab = w.get_tab_from_uri(uri);
        if (tab == null)
            continue;
        w.set_active_tab(tab);
        Gedit.View view = tab.get_view();
        Gedit.Document document = tab.get_document();
        Gtk.TextIter iter;
        document.get_iter_at_line(out iter, line - 1);
        view.scroll_to_iter(iter, 0.25, false, 0.0, 0.0);
        is_new = false;
        return tab;
    }
    is_new = true;
    return window.create_tab_from_uri(uri, null, line, false, true);
}

class Instance {
    public Gedit.Window window;
    Gtk.ActionGroup action_group;
    Gtk.Action build_action;
    uint ui_id;
    
    string build_directory;
    int saving;
    
    Gtk.TextTag error_tag;
    Gtk.TextTag italic_tag;
    Gtk.TextTag bold_tag;
    Gtk.TextTag highlight_tag;
    
    Gtk.TextBuffer output_buffer;
    Gtk.TextView output_view;
    Gtk.ScrolledWindow output_pane;
    
    string target_filename;
    Position target_start;
    Position target_end;
    
    const Gtk.ActionEntry[] entries = {
	    { "Project", null, "_Project" },   // top-level menu

	    { "ProjectBuild", Gtk.STOCK_CONVERT, "_Build", "<shift><ctrl>b",
	      "Build the project", on_build }
    };

    const string ui = """
        <ui>
          <menubar name="MenuBar">
            <placeholder name="ExtraMenu_1">
              <menu name="ProjectMenu" action="Project">
                <menuitem name="ProjectBuildMenu" action="ProjectBuild"/>
              </menu>
            </placeholder>
          </menubar>
        </ui>
    """;    

    public Instance(Gedit.Window window) {
        this.window = window;
        output_buffer = new Gtk.TextBuffer(null);
        
        error_tag = output_buffer.create_tag("error", "foreground", "#c00");
        italic_tag = output_buffer.create_tag("italic", "style", Pango.Style.OBLIQUE);
        bold_tag = output_buffer.create_tag("bold", "weight", Pango.Weight.BOLD);
        highlight_tag = output_buffer.create_tag("highlight",
            "foreground", "black", "background", "#abd");
        output_view = new Gtk.TextView.with_buffer(output_buffer);
        output_view.set_editable(false);
        output_view.set_cursor_visible(false);
        Pango.FontDescription font = Pango.FontDescription.from_string("Monospace");
        output_view.modify_font(font);
        output_view.button_press_event += on_button_press;
        
        output_pane = new Gtk.ScrolledWindow(null, null);
        output_pane.add(output_view);
        output_pane.show_all();
        
        Gedit.Panel panel = window.get_bottom_panel();
        panel.add_item_with_stock_icon(output_pane, "Build", Gtk.STOCK_CONVERT);

        Gtk.UIManager manager = window.get_ui_manager();
        
        action_group = new Gtk.ActionGroup("valencia");
        action_group.add_actions(entries, this);
        build_action = action_group.get_action("ProjectBuild");
        build_action.set_sensitive(false);
        manager.insert_action_group(action_group, 0);
        
        ui_id = manager.add_ui_from_string(ui, -1);
    }
    
    bool scroll_to_end() {
        Gtk.TextIter end;
        output_buffer.get_end_iter(out end);
        output_view.scroll_to_iter(end, 0.25, false, 0.0, 0.0);
        return false;
    }
    
    bool on_build_output(IOChannel source, bool error) {
        bool ret = true;
        bool appended = false;
        while (true) {
            string line;
            size_t length;
            size_t terminator_pos;
            IOStatus status;
            try {
                status = source.read_line(out line, out length, out terminator_pos);
            } catch (ConvertError e) {
                return false;   // TODO: report error
            } catch (IOChannelError e) {
                return false;   // TODO: report error
            }
            if (status == IOStatus.EOF) {
                if (error) {
                    append_with_tag(output_buffer, "\nBuild complete", italic_tag);
                    appended = true;
                }
                ret = false;
                break;
            }
            if (status != IOStatus.NORMAL)
                break;
            append_with_tag(output_buffer, line, error ? error_tag : null);
            appended = true;
        }
        if (appended)
            Idle.add(scroll_to_end);
        return ret;
    }
    
    bool on_build_stdout(IOChannel source, IOCondition condition) {
        return on_build_output(source, false);
    }
    
    bool on_build_stderr(IOChannel source, IOCondition condition) {
        return on_build_output(source, true);
    }
    
    void build() {
        output_buffer.set_text("", 0);
        
        Gedit.Document document = window.get_active_document();
        string filename = document_filename(document);
        build_directory = Path.get_dirname(filename);
        
        append_with_tag(output_buffer, "Running ", italic_tag);
        append_with_tag(output_buffer, "make ", bold_tag);
        append_with_tag(output_buffer, "in ", italic_tag);
        append_with_tag(output_buffer, build_directory, bold_tag);
        append(output_buffer, "\n\n");
        
        Gedit.Panel panel = window.get_bottom_panel();
        panel.activate_item(output_pane);
        panel.show();
        
        string[] argv = new string[2];
        argv[0] = "make";
        argv[1] = null;
        
        Pid child_pid;
        int input_fd;
        int output_fd;
        int error_fd;
        try {
        Process.spawn_async_with_pipes(
            build_directory,    // working directory
            argv,
            null,   // environment
            SpawnFlags.SEARCH_PATH,
            null,   // child_setup
            out child_pid,
            out input_fd,
            out output_fd,
            out error_fd);
        } catch (SpawnError e) {
            stderr.puts("spawn error");  // TODO: report using message dialog
            return;
        }
        
        try {
            make_pipe(output_fd, on_build_stdout);
            make_pipe(error_fd, on_build_stderr);        
        } catch (IOChannelError e) {
            stderr.puts("i/o error");   // TODO: report using message dialog
            return;
        }
    }

    void on_saved() {
        if (--saving == 0)
            build();
    }

    static void saved_callback(Gedit.Document document, void *arg1, Instance instance) {
        SignalHandler.disconnect_by_func(document, (void *) saved_callback, instance);
        instance.on_saved();
    }
    
    void on_build() {
        foreach (Gedit.Document d in Gedit.App.get_default().get_documents())
            if (!d.is_untitled() && !d.is_untouched()) {
                ++saving;
                Signal.connect(d, "saved", (Callback) saved_callback, this);
                d.save(0);
            }
        if (saving == 0)
            build();
    }
    
    void select(Gedit.Document document, Position start, Position end) {
        if (start.character != 0)
            select_range(document, start, end);
        else select_line(document, start.line);
    }
    
    void on_document_loaded(Gedit.Document document) {
        if (document_filename(document) == target_filename) {
            select(document, target_start, target_end);
            target_filename = null;
            target_start.line = 0;
        }
    }

    static void document_loaded_callback(Gedit.Document document, void *arg1, Instance instance) {
        instance.on_document_loaded(document);
    }

    void jump(string filename, Position start, Position end) {
        bool is_new;
        Gedit.Tab tab = navigate(window, filename, start.line, out is_new);
        Gedit.Document document = tab.get_document();
        if (is_new) {
            target_filename = filename;
            target_start = start;
            target_end = end;
            Signal.connect(document, "loaded", (Callback) document_loaded_callback, this);
        }
        else {
            select(document, start, end);
            tab.get_view().grab_focus();
        }
    }
    
    bool on_button_press(Gtk.TextView view, Gdk.EventButton event) {
        if (event.type != Gdk.EventType.2BUTTON_PRESS)  // double click?
            return false;   // return if not
        Gtk.TextIter start;
        Gtk.TextIter end;
        get_line_start_end(get_insert_iter(output_buffer), out start, out end);
        string line = output_buffer.get_text(start, end, true);
        Regex regex;
        try {
            // We look for two kinds of error lines:
            //   foo.vala:297.15-297.19: ...  (valac errors)
            //   foo.c:268: ...               (GCC errors, containing a line number only)
            regex = new Regex("""^(.*):(\d+)(?:\.(\d+)-(\d+)\.(\d+))?:""");
        } catch (RegexError e) {
            return true;    // TODO: report error
        }
        MatchInfo info;
        if (!regex.match(line, 0, out info))
            return true;    // no match
        Gtk.TextIter begin_buffer;
        Gtk.TextIter end_buffer;
        output_buffer.get_bounds(out begin_buffer, out end_buffer);
        output_buffer.remove_tag(highlight_tag, begin_buffer, end_buffer);
        output_buffer.apply_tag(highlight_tag, start, end);
        
        string filename = Path.build_filename(build_directory, info.fetch(1));
        int line_number = info.fetch(2).to_int();
        string match3 = info.fetch(3);
        if (match3 == null)     // line number only
            jump(filename, Position(line_number, 0), Position(0, 0));
        else {
            Position start_pos = Position(line_number, match3.to_int());
            Position end_pos = Position(info.fetch(4).to_int(), info.fetch(5).to_int() + 1);
            jump(filename, start_pos, end_pos);
        }
        return true;
    }

    public void update_ui() {
        Gedit.Document document = window.get_active_document();
        build_action.set_sensitive(document != null && document_filename(document) != null);
    }

    public void deactivate() {
        Gtk.UIManager manager = window.get_ui_manager();
        manager.remove_ui(ui_id);
        manager.remove_action_group(action_group);

        Gedit.Panel panel = window.get_bottom_panel();
        panel.remove_item(output_pane);
    }
}

class Plugin : Gedit.Plugin {
    Gee.ArrayList<Instance> instances = new Gee.ArrayList<Instance>();

    public override void activate(Gedit.Window window) {
        instances.add(new Instance(window));
    }
    
    Instance? find(Gedit.Window window) {
        foreach (Instance i in instances)
            if (i.window == window)
                return i;
        return null;
    }
    
    public override void deactivate(Gedit.Window window) {
        Instance i = find(window);
        i.deactivate();
        instances.remove(i);
    }
    
    public override void update_ui(Gedit.Window window) {
        Instance i = find(window);
        i.update_ui();
    }
}

[ModuleInit]
public Type register_gedit_plugin (TypeModule module) {
	return typeof (Plugin);
}

