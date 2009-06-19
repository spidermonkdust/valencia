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

abstract class Destination : Object {
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

class ErrorInfo : Object {
	public string filename;
	public string start_line;
	public string start_char;
	public string end_line;
	public string end_char;
}

class ErrorPair : Object {
    public Gtk.TextMark document_pane_error;
    public Gtk.TextMark build_pane_error;
    public ErrorInfo error_info;
    
    ErrorPair(Gtk.TextMark document_err, Gtk.TextMark build_err, ErrorInfo err_info) {
        document_pane_error = document_err;
        build_pane_error = build_err;
        error_info = err_info;
    }
}

class ProgramErrorList : Object {
    public weak Program program;
    public Gee.ArrayList<ErrorPair> error_history;
    public int error_index;
    
    ProgramErrorList(Program program) {
        this.program = program;
        error_history = new Gee.ArrayList<ErrorPair>();
        error_index = -1;    
    }
}

class Instance : Object {
    public Gedit.Window window;
    Plugin plugin;
    Program last_program_to_build;
        
    Gtk.ActionGroup action_group;
    Gtk.MenuItem go_to_definition_menu_item;
    Gtk.MenuItem go_back_menu_item;
    Gtk.MenuItem build_menu_item;
    Gtk.MenuItem next_error_menu_item;
    Gtk.MenuItem prev_error_menu_item;
    uint ui_id;
    
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

    static ArrayList<Gtk.TextMark> history;
    const int MAX_HISTORY = 10;
    
    static Gee.ArrayList<ProgramErrorList> program_error_list;
    
    const Gtk.ActionEntry[] entries = {
        { "SearchGoToDefinition", null, "Go to _Definition", "F12",
          "Jump to a symbol's definition", on_go_to_definition },
        { "SearchGoBack", Gtk.STOCK_GO_BACK, "Go _Back", "<alt>Left",
          "Go back after jumping to a definition", on_go_back },
	    { "SearchNextError", null, "_Next Error", "<ctrl><alt>n",
	      "Go to the next compiler error in the ouput and view panes", on_next_error },
	    { "SearchPrevError", null, "_Previous Error", "<ctrl><alt>p",
	      "Go to the previous compiler error in the ouput and view panes", on_prev_error },
        
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
                <menuitem name="SearchGoBackMenu" action="SearchGoBack"/>
                <separator/>
                <menuitem name="SearchNextErrorMenu" action="SearchNextError"/>
                <menuitem name="SearchPrevErrorMenu" action="SearchPrevError"/>
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

    public Instance(Gedit.Window window, Plugin plugin) {
        this.window = window;
        this.plugin = plugin;
        
        if (history == null)
        	history = new ArrayList<Gtk.TextMark>();

        if (program_error_list == null) {
            program_error_list = new ArrayList<ProgramErrorList>();
        }
        
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
        output_pane.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC);
        output_pane.add(output_view);
        output_pane.show_all();
        
        Gedit.Panel panel = window.get_bottom_panel();
        panel.add_item_with_stock_icon(output_pane, "Build", Gtk.STOCK_CONVERT);

        Gtk.UIManager manager = window.get_ui_manager();
        
        action_group = new Gtk.ActionGroup("valencia");
        action_group.add_actions(entries, this);
        manager.insert_action_group(action_group, 0);
        
        ui_id = manager.add_ui_from_string(ui, -1);
        
        Gtk.MenuItem search_menu = (Gtk.MenuItem) manager.get_widget("/MenuBar/SearchMenu");
        if (search_menu != null)
            search_menu.activate += on_search_menu_activated;
        else critical("null search_menu");
        
        Gtk.MenuItem project_menu = (Gtk.MenuItem) manager.get_widget("/MenuBar/ExtraMenu_1/ProjectMenu");
        if (project_menu != null)
            project_menu.activate += on_project_menu_activated;
        else critical("null project_menu");
        
        go_to_definition_menu_item = (Gtk.MenuItem) manager.get_widget(
            "/MenuBar/SearchMenu/SearchOps_8/SearchGoToDefinitionMenu");
        assert(go_to_definition_menu_item != null);
        
        go_back_menu_item = (Gtk.MenuItem) manager.get_widget(
            "/MenuBar/SearchMenu/SearchOps_8/SearchGoBackMenu");
        assert(go_back_menu_item != null);

        next_error_menu_item = (Gtk.MenuItem) manager.get_widget(
            "/MenuBar/SearchMenu/SearchOps_8/SearchNextErrorMenu");
        assert(next_error_menu_item != null);
        
        prev_error_menu_item = (Gtk.MenuItem) manager.get_widget(
            "/MenuBar/SearchMenu/SearchOps_8/SearchPrevErrorMenu");
        assert(prev_error_menu_item != null);
        
        build_menu_item = (Gtk.MenuItem) manager.get_widget(
            "/MenuBar/ExtraMenu_1/ProjectMenu/ProjectBuildMenu");
        assert(build_menu_item != null);

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
                    
                    // Always regenerate the list *after* a new build
                    ProgramErrorList program_errors = get_document_error_history();
                    generate_error_history(program_errors);
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
    
    void hide_old_build_output() {
        foreach (Instance instance in plugin.instances) {
            if (instance != this && last_program_to_build == instance.last_program_to_build) {
                instance.output_pane.hide();
                instance.last_program_to_build = null;
            }
        }
    }
    
    string get_active_document_filename() {
        Gedit.Document document = window.get_active_document();
        return document_filename(document);
    }
    
    void show_output_pane() {
        output_pane.show();
        Gedit.Panel panel = window.get_bottom_panel();
        panel.activate_item(output_pane);
        panel.show();
    }

    void build() {
        string filename = get_active_document_filename();

        // Record the last program to build in this window so that we don't accidentally hide
        // output that isn't part of a program that gets built later
        last_program_to_build = Program.find_containing(filename);
        
        hide_old_build_output();
       
        output_buffer.set_text("", 0);
        
        append_with_tag(output_buffer, "Running ", italic_tag);
        append_with_tag(output_buffer, "make ", bold_tag);
        append_with_tag(output_buffer, "in ", italic_tag);
        append_with_tag(output_buffer, last_program_to_build.get_top_directory(), bold_tag);
        append(output_buffer, "\n\n");
        
        output_pane.show();
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
            last_program_to_build.get_top_directory(),    // working directory
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
    
    void scroll_tab_to_iter(Gedit.Tab tab, Gtk.TextIter iter) {
	    Gedit.View view = tab.get_view();
	    view.scroll_to_iter(iter, 0.2, false, 0.0, 0.0);
        view.grab_focus();
    }
    
    void go(Gedit.Tab tab, Destination dest) {
	    Gedit.Document document = tab.get_document();
	    Gtk.TextIter start;
	    Gtk.TextIter end;
	    dest.get_range(document, out start, out end);
        document.select_range(start, end);
        scroll_tab_to_iter(tab, start);
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
            w.present();		    
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
	        stderr.puts("A RegexError occured when creating a new regular expression.\n");
	    	return;		// TODO: report error
	    }
    }
    
    string get_line(Gtk.TextIter iter) {
        Gtk.TextIter start;
        Gtk.TextIter end;
        weak Gtk.TextBuffer buffer = iter.get_buffer();
        get_line_start_end(iter, out start, out end);
        return buffer.get_text(start, end, true);
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
    
    void tag_text_buffer_line(Gtk.TextBuffer buffer, Gtk.TextTag tag, Gtk.TextIter iter) {
        Gtk.TextIter start;
        Gtk.TextIter end;
        buffer.get_bounds(out start, out end);
        buffer.remove_tag(tag, start, end);
        get_line_start_end(iter, out start, out end);
        buffer.apply_tag(tag, start, end);
    }

    void jump_to_document_error(Gtk.TextIter iter, ErrorInfo info, Program current_program) {
        string filename = Path.build_filename(current_program.get_top_directory(), 
                                              info.filename);
        int line_number = info.start_line.to_int();
        Destination dest;
        if (info.start_char == null)
        	dest = new LineNumber(line_number - 1);
        else
        	dest = new LineCharRange(line_number - 1, info.start_char.to_int() - 1,
        					         info.end_line.to_int() - 1, info.end_char.to_int());
        
        jump(filename, dest);
    }
    
    void update_error_history_index(ProgramErrorList program_errors, ErrorInfo info) {
        program_errors.error_index = -1;
        foreach (ErrorPair pair in program_errors.error_history) {
            ++program_errors.error_index;
            
            if (info.start_line == pair.error_info.start_line)
                return;
        }
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

        tag_text_buffer_line(output_buffer, highlight_tag, iter);
        
        // It is last_program_to_build because the output window being clicked on is obviously
        // from this same instance, which means the last program output to this instance's buffer
        jump_to_document_error(iter, info, last_program_to_build);
        ProgramErrorList program_errors = get_program_error_list_from_program(last_program_to_build);
        update_error_history_index(program_errors, info);

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
        Gtk.TextIter insert = get_insert_iter(document);
        int pos = insert.get_offset();
        CompoundName name = new Parser().name_at(source, pos);
        if (name == null)
        	return;
        
        SourceFile sf = program.find_source(filename);
		Symbol sym = sf.resolve(name, pos);
		if (sym == null)
			return;

		Gtk.TextMark mark = document.create_mark(null, insert, false);
		history.add(mark);
		if (history.size > MAX_HISTORY)
		    history.remove_at(0);

		SourceFile dest = sym.source;
		jump(dest.filename, new CharRange(sym.start, sym.start + (int) sym.name.length));
	}

    void move_output_mark_into_focus(Gtk.TextMark mark) {
        Gtk.TextBuffer output = mark.get_buffer();
        Gtk.TextIter iter;
        output.get_iter_at_mark(out iter, mark);
        output_view.scroll_to_iter(iter, 0.25, true, 0.0, 0.0);
        
        show_output_pane();
        tag_text_buffer_line(output_buffer, highlight_tag, iter);
    }

	void on_go_back() {
		if (history.size == 0)
			return;

		Gtk.TextMark mark = history.get(history.size - 1);
		history.remove_at(history.size - 1);
		assert(!mark.get_deleted());

		Gedit.Document buffer = (Gedit.Document) mark.get_buffer();
		Gtk.TextIter iter;
		buffer.get_iter_at_mark(out iter, mark);
		buffer.delete_mark(mark);
		buffer.place_cursor(iter);
		
		Gedit.Tab tab = Gedit.Tab.get_from_document(buffer);
	    Gedit.Window window = (Gedit.Window) tab.get_toplevel();
	    window.set_active_tab(tab);
		window.present();
	    
	    scroll_tab_to_iter(tab, iter);
	}

    bool can_go_back() {
        if (history.size == 0)
            return false;
		Gtk.TextMark mark = history.get(history.size - 1);
        return !mark.get_deleted();
    }

    string active_filename() {
        Gedit.Document document = window.get_active_document();
        return document == null ? null : document_filename(document);
    }
    
    void clear_error_history(Gee.ArrayList<ErrorPair> error_history) {
        if (error_history.size == 0)
            return;

        // Before clearing the ArrayList, clean up the TextMarks stored in the buffers
        foreach (ErrorPair pair in error_history) {
            Gtk.TextMark mark = pair.document_pane_error;
            Gtk.TextBuffer buffer = mark.get_buffer();
            buffer.delete_mark(mark);

            mark = pair.build_pane_error;
            buffer = mark.get_buffer();
            buffer.delete_mark(mark);    
        }
       
        error_history.clear();
    }

    void generate_error_history(ProgramErrorList program_errors) {
        clear_error_history(program_errors.error_history);

        // Starting at the first line, search for errors downward
        Gtk.TextIter iter = get_insert_iter(output_buffer);
        iter.set_line(0);
        ErrorInfo einfo;
        program_errors.error_index = -1;
        bool end_of_buffer = false;
        
        while (!end_of_buffer) {
            // Check the current line for errors
            einfo = error_info(iter);
            if (einfo != null) {
                Gedit.Document document = window.get_active_document();
                Gtk.TextIter document_iter
                document.get_iter_at_line(out document_iter, einfo.start_line.to_int());
              
                Gtk.TextMark doc_mark = document.create_mark(null, document_iter, false);
                Gtk.TextMark build_mark = output_buffer.create_mark(null, iter, false);
                
                ErrorPair pair = new ErrorPair(doc_mark, build_mark, einfo);
                program_errors.error_history.add(pair)
            }                
            
            end_of_buffer = !iter.forward_line();
        }
    }

    Instance? find_build_instance(Program cur_program) {
        foreach (Instance inst in plugin.instances) {
            if (inst.last_program_to_build != null && 
                inst.last_program_to_build.get_top_directory() == cur_program.get_top_directory()) {
                    return inst;
                }
        }
        
        return null;
    }

    void move_to_error(ProgramErrorList program_errors) {
        ErrorPair pair = program_errors.error_history[program_errors.error_index];

        Gtk.TextBuffer document = pair.document_pane_error.get_buffer();
        Gtk.TextIter doc_iter;
        document.get_iter_at_mark(out doc_iter, pair.document_pane_error);
        
        Instance target = find_build_instance(program_errors.program);
        if (target == null)
            return;
            
        jump_to_document_error(doc_iter, pair.error_info, program_errors.program);
        target.move_output_mark_into_focus(pair.build_pane_error);
    }

    ProgramErrorList get_program_error_list_from_program(Program program) {
        foreach (ProgramErrorList program_errors in program_error_list) {
            if (program_errors.program.get_top_directory() == program.get_top_directory())
                return program_errors;
        }
        
        // Since no ProgramErrorList exists for this file yet, create one
        ProgramErrorList new_program_errors = new ProgramErrorList(program);
        program_error_list.add(new_program_errors);
        return new_program_errors;
    }
    
    ProgramErrorList? get_document_error_history() {
        Gedit.Document document = window.get_active_document();
        string filename = document_filename(document);
        Program document_program = Program.find_containing(filename);
        
        foreach (ProgramErrorList p in program_error_list) {
            if (p.program == document_program)
                return p;
        }
        
        // Since no ProgramErrorList exists for this file yet, create one
        ProgramErrorList new_program_errors = new ProgramErrorList(document_program);
        program_error_list.add(new_program_errors);
        return new_program_errors;
    }
    
    bool active_document_is_valid_vala_file() {
        string filename = active_filename();
        return filename != null && Program.is_vala(filename);
    }
        
    void on_next_error() {
        if (active_filename() == null)
            return;
    
        ProgramErrorList program_errors = get_document_error_history();
        
        if (program_errors == null || program_errors.error_history.size == 0)
            return;
    
        if (program_errors.error_index < program_errors.error_history.size - 1)
            ++program_errors.error_index;
        
        move_to_error(program_errors);
    }
    
    void on_prev_error() {
        if (active_filename() == null)
            return;
    
        ProgramErrorList program_errors = get_document_error_history();
        
        if (program_errors == null || program_errors.error_history.size == 0)
            return;
    
        if (program_errors.error_index > 0)
            --program_errors.error_index;
        
        move_to_error(program_errors);
    }
    
    bool errors_exist() {
        ProgramErrorList program_errors = get_document_error_history();
        return program_errors.error_history.size != 0;
    }

    void on_search_menu_activated() {
        bool definition_item_sensitive = active_document_is_valid_vala_file();
        go_to_definition_menu_item.set_sensitive(definition_item_sensitive);
        go_back_menu_item.set_sensitive(can_go_back());
        
        bool activate_error_search = active_filename() != null && errors_exist();
        next_error_menu_item.set_sensitive(activate_error_search);
        prev_error_menu_item.set_sensitive(activate_error_search);
    }
    
    void on_project_menu_activated() {
        build_menu_item.set_sensitive(active_filename() != null);
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
    public Gee.ArrayList<Instance> instances = new Gee.ArrayList<Instance>();

    public override void activate(Gedit.Window window) {
        Instance new_instance = new Instance(window, this);
        instances.add(new_instance);
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
}

[ModuleInit]
public Type register_gedit_plugin (TypeModule module) {
	return typeof (Plugin);
}

