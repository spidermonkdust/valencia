using Gee;

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

Gtk.TextIter iter_at_line_offset(Gtk.TextBuffer buffer, int line, int offset) {
    // We must be careful: TextBuffer.get_iter_at_line_offset() will crash if we give it an
    // offset greater than the length of the line.
    Gtk.TextIter iter;
    buffer.get_iter_at_line(out iter, line);
    int len = iter.get_chars_in_line() - 1;     // subtract 1 for \n
    if (len < 0)	// no \n was present, e.g. in an empty file
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

string? filename_to_uri(string filename) {
    try {
        return Filename.to_uri(filename);
    } catch (ConvertError e) { return null; }
}

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

abstract class Destination {
	public abstract void get_range(Gtk.TextBuffer buffer,
								   out Gtk.TextIter start, out Gtk.TextIter end);
}

class LineNumber : Destination {
	int line;	// starting from 0
	
	public LineNumber(int line) { this.line = line; }
	
	public override void get_range(Gtk.TextBuffer buffer,
								   out Gtk.TextIter start, out Gtk.TextIter end) {
		Gtk.TextIter iter;
		buffer.get_iter_at_line(out iter, line);
		get_line_start_end(iter, out start, out end);
	}
}

class LineCharRange : Destination {
	int start_line;		// starting from 0
	int start_char;
	int end_line;
	int end_char;
	
	public LineCharRange(int start_line, int start_char, int end_line, int end_char) {
		this.start_line = start_line;
		this.start_char = start_char;
		this.end_line = end_line;
		this.end_char = end_char;
	}
	
	public override void get_range(Gtk.TextBuffer buffer,
								   out Gtk.TextIter start, out Gtk.TextIter end) {
	    start = iter_at_line_offset(buffer, start_line, start_char);
	    end = iter_at_line_offset(buffer, end_line, end_char);
	}
}

class CharRange : Destination {
	int start_char;
	int end_char;
	
	public CharRange(int start_char, int end_char) {
		this.start_char = start_char;
		this.end_char = end_char;
	}
	
	public override void get_range(Gtk.TextBuffer buffer,
								   out Gtk.TextIter start, out Gtk.TextIter end) {
		buffer.get_iter_at_offset(out start, start_char);
		buffer.get_iter_at_offset(out end, end_char);
	}	
}

class Instance {
    public Gedit.Window window;
    Gtk.ActionGroup action_group;
    Gtk.Action go_to_definition_action;
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
    
    Regex error_regex;
    
    string target_filename;
    Destination destination;
    
    const Gtk.ActionEntry[] entries = {
        { "SearchGoToDefinition", null, "Go to _Definition", "F12",
          "Jump to a symbol's definition", on_go_to_definition },
        
	    { "Project", null, "_Project" },   // top-level menu

	    { "ProjectBuild", Gtk.STOCK_CONVERT, "_Build", "<shift><ctrl>b",
	      "Build the project", on_build }
    };

    const string ui = """
        <ui>
          <menubar name="MenuBar">
            <menu name="SearchMenu" action="Search">
              <placeholder name="SearchOps_8">
                <menuitem name="SearchGoToDefinitionMenu" action="SearchGoToDefinition"/>
              </placeholder>
            </menu>
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
        go_to_definition_action = action_group.get_action("SearchGoToDefinition");
        build_action = action_group.get_action("ProjectBuild");
        update_ui();
        manager.insert_action_group(action_group, 0);
        
        ui_id = manager.add_ui_from_string(ui, -1);
        
        init_error_regex();
        
        Signal.connect(window, "tab-added", (Callback) tab_added_callback, this);
        Signal.connect(window, "tab-removed", (Callback) tab_removed_callback, this);
    }

	static void tab_added_callback(Gedit.Window window, Gedit.Tab tab, Instance instance) {
		Gedit.Document document = tab.get_document();
		Signal.connect(document, "saved", (Callback) all_save_callback, instance);
	}
	
	static void tab_removed_callback(Gedit.Window window, Gedit.Tab tab, Instance instance) {
		Gedit.Document document = tab.get_document();
		if (document.get_modified()) {
			// We're closing a document without saving changes.  Reparse the symbol tree
			// from the source file on disk.
			string path = document_filename(document);
			if (path != null)
				Program.update_any(path, null);
		}
	}
	
	// TODO: Merge this method with saved_callback, below.
    static void all_save_callback(Gedit.Document document, void *arg1, Instance instance) {
		string path = document_filename(document);
   		Program.update_any(path, buffer_contents(document));
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
            if (!d.is_untitled() && d.get_modified()) {
                ++saving;
                Signal.connect(d, "saved", (Callback) saved_callback, this);
                d.save(0);
            }
        if (saving == 0)
            build();
    }
    
    void go(Gedit.Tab tab, Destination dest) {
	    Gedit.Document document = tab.get_document();
	    Gtk.TextIter start;
	    Gtk.TextIter end;
	    dest.get_range(document, out start, out end);
        document.select_range(start, end);
        
	    Gedit.View view = tab.get_view();
	    view.scroll_to_iter(start, 0.2, false, 0.0, 0.0);
        view.grab_focus();
    }
    
    void on_document_loaded(Gedit.Document document) {
        if (document_filename(document) == target_filename) {
        	Gedit.Tab tab = Gedit.Tab.get_from_document(document);
            go(tab, destination);
            target_filename = null;
            destination = null;
        }
    }

    static void document_loaded_callback(Gedit.Document document, void *arg1, Instance instance) {
        instance.on_document_loaded(document);
    }

    void jump(string filename, Destination dest) {
		Gedit.Window w;
		Gedit.Tab tab = find_tab(filename, out w);
		if (tab != null) {
		    w.set_active_tab(tab);
		    go(tab, dest);
            return;
		}
		
		tab = window.create_tab_from_uri(filename_to_uri(filename), null, 0, false, true);
        target_filename = filename;
        destination = dest;
        Signal.connect(tab.get_document(), "loaded", (Callback) document_loaded_callback, this);
    }
    
    // We look for two kinds of error lines:
    //   foo.vala:297.15-297.19: ...  (valac errors)
    //   foo.c:268: ...               (GCC errors, containing a line number only)
    void init_error_regex() {
    	try {
	    	error_regex = new Regex("""^(.*):(\d+)(?:\.(\d+)-(\d+)\.(\d+))?:""");
	    } catch (RegexError e) {
	    	return;		// TODO: report error
	    }
    }
    
    class ErrorInfo {
    	public string filename;
    	public string start_line;
    	public string start_char;
    	public string end_line;
    	public string end_char;
    }
    
    string get_line(Gtk.TextIter iter) {
        Gtk.TextIter start;
        Gtk.TextIter end;
        get_line_start_end(iter, out start, out end);
        return output_buffer.get_text(start, end, true);
    }
    
    // Look for error position information in the line containing the given iterator.
    ErrorInfo? error_info(Gtk.TextIter iter) {
        string line = get_line(iter);
        MatchInfo info;
        if (error_regex.match(line, 0, out info)) {
        	ErrorInfo e = new ErrorInfo();
        	e.filename = info.fetch(1);
        	e.start_line = info.fetch(2);
        	e.start_char = info.fetch(3);
        	e.end_line = info.fetch(4);
        	e.end_char = info.fetch(5);
        	return e;
        }
        else return null;
    }
    
    // Return true if s is composed of ^^^ characters pointing to an error snippet above.
    bool is_snippet_marker(string s) {
    	weak string p = s;
    	while (p != "") {
    		unichar c = p.get_char();
    		if (!c.isspace() && c != '^')
    			return false;
    		p = p.next_char();
    	}
    	return true;
    }
    
    bool on_button_press(Gtk.TextView view, Gdk.EventButton event) {
        if (event.type != Gdk.EventType.2BUTTON_PRESS)  // double click?
            return false;   // return if not
        Gtk.TextIter iter = get_insert_iter(output_buffer);
        ErrorInfo info = error_info(iter);
        if (info == null) {
        	// Is this an error snippet?
        	Gtk.TextIter next = iter;
        	if (!next.forward_line() || !is_snippet_marker(get_line(next)))
        		return false;
        	
        	// Yes; look for error information on the previous line.
        	Gtk.TextIter prev = iter;
        	if (prev.backward_line())
        		info = error_info(prev);
        }
        if (info == null)
        	return false;
        
        Gtk.TextIter start;
        Gtk.TextIter end;
        output_buffer.get_bounds(out start, out end);
        output_buffer.remove_tag(highlight_tag, start, end);
        get_line_start_end(iter, out start, out end);
        output_buffer.apply_tag(highlight_tag, start, end);
        
        string filename = Path.build_filename(build_directory, info.filename);
        int line_number = info.start_line.to_int();
        Destination dest;
        if (info.start_char == null)
        	dest = new LineNumber(line_number - 1);
        else
        	dest = new LineCharRange(line_number - 1, info.start_char.to_int() - 1,
        					         info.end_line.to_int() - 1, info.end_char.to_int());
        jump(filename, dest);
        return true;
    }

    void on_go_to_definition() {
        Gedit.Document document = window.get_active_document();
        string filename = document_filename(document);
        if (filename == null)
        	return;
        Program program = Program.find_containing(filename);

		// Reparse any modified documents in this program.
	    foreach (Gedit.Document d in Gedit.App.get_default().get_documents())
	    	if (d.get_modified()) {
	    		string path = document_filename(d);
	    		if (path != null)
		    		program.update(path, buffer_contents(d));
	    	}
        
        weak string source = buffer_contents(document);
        int pos = get_insert_iter(document).get_offset();
        CompoundName name = new Parser().name_at(source, pos);
        
        SourceFile sf = program.find_source(filename);
		Symbol sym = sf.resolve(name, pos);
		if (sym == null)
			return;
		
		SourceFile dest = sym.source;
		jump(dest.filename, new CharRange(sym.start, sym.start + (int) sym.name.length));
	}

    public void update_ui() {
        Gedit.Document document = window.get_active_document();
        string filename = document == null ? null : document_filename(document);
        build_action.set_sensitive(filename != null);
        go_to_definition_action.set_sensitive(filename != null && Program.is_vala(filename));
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

