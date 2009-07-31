/* Copyright 2009 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

using Gee;
using Vte;

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
    int line;    // starting from 0
    
    public LineNumber(int line) { this.line = line; }
    
    public override void get_range(Gtk.TextBuffer buffer,
                                   out Gtk.TextIter start, out Gtk.TextIter end) {
        Gtk.TextIter iter;
        buffer.get_iter_at_line(out iter, line);
        get_line_start_end(iter, out start, out end);
    }
}

class LineCharRange : Destination {
    int start_line;        // starting from 0
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

class ScanScope : Object {
    public int depth;
    public int start_pos;
    public int end_pos;
    
    public ScanScope(int depth, int start_pos, int end_pos) {
        this.depth = depth;
        this.start_pos = start_pos;
        this.end_pos = end_pos;
    }
}

class AutocompleteDialog : Object {
    weak Gedit.Window parent;
    Gtk.Window window;
    Gtk.ListStore list;
    Gtk.TreeView treeview;
    Gtk.TreeViewColumn column_view;
    Gtk.ScrolledWindow scrolled_window;
    bool visible;
    string partial_name;

    public AutocompleteDialog(Gedit.Window parent_win) {
        parent = parent_win;
        visible = false;
        list = new Gtk.ListStore(1, GLib.Type.from_name("gchararray"));

        Gtk.CellRendererText renderer = new Gtk.CellRendererText();
        column_view = new Gtk.TreeViewColumn();
        column_view.pack_start(renderer, true); 
        column_view.set_sizing(Gtk.TreeViewColumnSizing.AUTOSIZE);
        column_view.set_attributes(renderer, "text", 0, null);
        treeview = new Gtk.TreeView.with_model(list);
        treeview.append_column(column_view);
        treeview.headers_visible = false;

        scrolled_window = new Gtk.ScrolledWindow(null, null); 
        scrolled_window.hscrollbar_policy = Gtk.PolicyType.NEVER;
        scrolled_window.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
        scrolled_window.add(treeview);

        window = new Gtk.Window(Gtk.WindowType.POPUP); 
        window.add(scrolled_window);
        window.set_destroy_with_parent(true);
        window.set_default_size(200, 1); 
        window.set_resizable(true);
        window.set_title("");
        window.set_border_width(1);
        
        window.show_all();
        window.hide();

        Signal.connect(window, "expose-event", (Callback) draw_callback, this);
        Signal.connect(treeview, "row-activated", (Callback) row_activated_callback, this);
    }

    static bool draw_callback(Gtk.Window window, Gdk.EventExpose event, AutocompleteDialog dialog) {
        Gtk.paint_flat_box(dialog.window.style, dialog.window.window, 
                           Gtk.StateType.NORMAL, Gtk.ShadowType.OUT, 
                           null, dialog.window, "tooltip",
                           dialog.window.allocation.x, dialog.window.allocation.y,
                           dialog.window.allocation.width, dialog.window.allocation.height);

        dialog.scrolled_window.expose_event(event);

        return true;
    }

    static void row_activated_callback(Gtk.TreeView view, Gtk.TreePath path, 
                                       Gtk.TreeViewColumn column, AutocompleteDialog dialog) {
        dialog.select_item();
    }

    public void show(SymbolSet symbol_set) {
        list.clear();
        visible = true;
        partial_name = symbol_set.get_name();

       string[] symbols = symbol_set.get_symbols();

        if (symbols != null) {
            foreach (string s in symbols) {
                Gtk.TreeIter iterator;
                list.append(out iterator);
                list.set(iterator, 0, s, -1);
            }
        } else {
            hide();
            return;
        }

        // TODO: this must be updated to account for font size changes when adding ticket #560        
        int size = list.iter_n_children(null);
        if (size > 6) {
            scrolled_window.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
            window.resize(200, 140);
        } else {
            scrolled_window.vscrollbar_policy = Gtk.PolicyType.NEVER;
            window.resize(200, size * 23);
        }

        treeview.get_hadjustment().set_value(0);
        treeview.get_vadjustment().set_value(0);

        Gedit.Document document = parent.get_active_document(); 
        Gtk.TextMark insert_mark = document.get_insert();
        Gtk.TextIter insert_iter;
        document.get_iter_at_mark(out insert_iter, insert_mark); 
        int x, y;
        get_coords_at_buffer_offset(parent, insert_iter.get_offset(), false, true, out x, out y);

        window.move(x, y);
        window.show_all(); 
        window.queue_draw();
        select_first_cell();
    }
    
    public void hide() {
        if (!visible)
            return;
        
        visible = false;
        window.hide();
    }

    public bool is_visible() {
        return visible;
    }

    void select(Gtk.TreePath path, bool scroll = true) {
        treeview.set_cursor(path, null, false);
        if (scroll)
            treeview.scroll_to_cell(path, null, false, 0.0f, 0.0f);
    }

    void scroll_to_and_select_cell(double adjustment_value, int y) {
        scrolled_window.vadjustment.set_value(adjustment_value);        
        
        Gtk.TreePath path;
        int cell_x, cell_y;
        treeview.get_path_at_pos(0, y, out path, null, out cell_x, out cell_y);
        select(path, false);
    }
    
    Gtk.TreePath get_path_at_cursor() {
        Gtk.TreePath path;
        Gtk.TreeViewColumn column;
        treeview.get_cursor(out path, out column);
        return path;
    }

    public Gtk.TreePath select_first_cell() {
        Gtk.TreePath start = new Gtk.TreePath.first();
        select(start);
        return start;
    }

    public void select_last_cell() {
        // The list index is 0-based, the last element is 'size - 1'
        int size = list.iter_n_children(null) - 1;
        select(new Gtk.TreePath.from_string(size.to_string()));
    }

    public void select_previous() {
        Gtk.TreePath path = get_path_at_cursor();
        
        if (path != null) {
            if (path.prev())
                select(path);
            else select_last_cell();
        }
    }

    public void select_next() {
        Gtk.TreePath path = get_path_at_cursor();
        
        if (path != null) {
            Gtk.TreeIter iter;
            path.next();

            // Make sure the next element iterator is valid
            if (list.get_iter(out iter, path))
                select(path);
            else select_first_cell();
        }
    }

    public void page_up() {
        // Save the current y position of the selection
        Gtk.TreePath cursor_path = get_path_at_cursor();
        Gdk.Rectangle rect;
        treeview.get_cell_area(cursor_path, null, out rect);
        
        // Don't wrap page_up
        if (!cursor_path.prev()) {
            return;
        }

        double adjust_value = scrolled_window.vadjustment.get_value();
        double page_size = scrolled_window.vadjustment.get_page_size();
        // If the current page is the top page, just select the top cell
        if (adjust_value == scrolled_window.vadjustment.lower) {
            select_first_cell();
            return;
        }

        // it is 'y + 1' because only 'y' would be the element before the one we want
        scroll_to_and_select_cell(adjust_value - (page_size - rect.height), rect.y + 1);
    }

    public void page_down() {
        // Save the current y position of the selection
        Gtk.TreePath cursor_path = get_path_at_cursor();
        Gdk.Rectangle rect;
        treeview.get_cell_area(cursor_path, null, out rect);
        
        // Don't wrap page_down
        cursor_path.next();
        Gtk.TreeIter iter;
        if (!list.get_iter(out iter, cursor_path)) {
            return;
        }

        double adjust_value = scrolled_window.vadjustment.get_value();
        double page_size = scrolled_window.vadjustment.get_page_size();
        // If the current page is the bottom page, just select the last cell
        if (adjust_value >= scrolled_window.vadjustment.upper - page_size) {
            select_last_cell();
            return;
        }

        scroll_to_and_select_cell(adjust_value + (page_size - rect.height), rect.y + 1);
    }

    public void select_item() {
        Gedit.Document buffer = parent.get_active_document();
        Gtk.TreePath path;
        Gtk.TreeViewColumn column;
        treeview.get_cursor(out path, out column);
        
        Gtk.TreeIter iter;
        list.get_iter(out iter, path);
        GLib.Value v;
        list.get_value(iter, 0, out v);

        weak string selection = v.get_string();
        string completed = selection.substring(partial_name.length);

        long offset = (selection.has_suffix(")")) ? 1 : 0;
        buffer.insert_at_cursor(completed, (int) (completed.length - offset));

        hide();
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

class ErrorList : Object {
    public Gee.ArrayList<ErrorPair> errors;
    public int error_index;
    
    ErrorList() {
        errors = new Gee.ArrayList<ErrorPair>();
        error_index = -1;    
    }
}

class Instance : Object {
    public Gedit.Window window;
    Plugin plugin;
    Program last_program_to_build;

    Gtk.ActionGroup action_group;
    Gtk.MenuItem go_to_definition_menu_item;
    Gtk.MenuItem go_to_enclosing_method_or_class_menu_item;
    Gtk.MenuItem go_back_menu_item;
    Gtk.MenuItem go_forward_menu_item;
    Gtk.MenuItem next_error_menu_item;
    Gtk.MenuItem prev_error_menu_item;
    Gtk.MenuItem build_menu_item;
    Gtk.MenuItem run_menu_item;
    Gtk.MenuItem display_tooltip_menu_item;

    uint ui_id;
    
    int saving;
    bool child_process_running;

    // Output pane
    Gtk.TextTag error_tag;
    Gtk.TextTag italic_tag;
    Gtk.TextTag bold_tag;
    Gtk.TextTag highlight_tag;
    
    Gtk.TextBuffer output_buffer;
    Gtk.TextView output_view;
    Gtk.ScrolledWindow output_pane;

    // Parsing dialog
    ProgressBarDialog parsing_dialog;

    // Run command
    Gtk.ScrolledWindow run_pane;
    Vte.Terminal run_terminal;
    
    Regex error_regex;
    
    string target_filename;
    Destination destination;

    // Jump to definition history
    static ArrayList<Gtk.TextMark> history;
    const int MAX_HISTORY = 10;
    int history_index;
    bool browsing_history;

    // Tooltips
    Tooltip tip;
    AutocompleteDialog autocomplete;

    // Signal handlers
    GLib.SList<Pair<weak GLib.Object, ulong>> signal_handler_list;
    
    // Display enclosing class in statusbar
    int old_cursor_offset;
    
    // Menu item entries
    const Gtk.ActionEntry[] entries = {
        { "SearchGoToDefinition", null, "Go to _Definition", "F12",
          "Jump to a symbol's definition", on_go_to_definition },
        { "SearchGoToEnclosingMethod", null, "Go to enclosing _method or class", "<ctrl>F12",
          "Jump to the enclosing method or class", on_go_to_enclosing_method_or_class },
        { "SearchGoBack", Gtk.STOCK_GO_BACK, "Go _Back", "<alt>Left",
          "Go back after jumping to a definition", on_go_back },
        { "SearchGoForward", Gtk.STOCK_GO_FORWARD, "Go F_orward", "<alt>Right",
          "Go forward to a definition after jumping backwards", on_go_forward },
        { "SearchNextError", null, "_Next Error", "<ctrl><alt>n",
          "Go to the next compiler error in the ouput and view panes", on_next_error },
        { "SearchPrevError", null, "_Previous Error", "<ctrl><alt>p",
          "Go to the previous compiler error in the ouput and view panes", on_prev_error },
        { "SearchAutocomplete", null, "_Autocomplete", "<ctrl>space",
          "Display a tooltip for the method you are typing", on_display_tooltip_or_autocomplete },
        
        { "Project", null, "_Project" },   // top-level menu

        { "ProjectBuild", Gtk.STOCK_CONVERT, "_Build", "<ctrl><alt>b",
          "Build the project", on_build },
        { "ProjectRun", Gtk.STOCK_EXECUTE, "_Run", "<ctrl><alt>r",
          "Build the project", on_run }
    };

    const string ui = """
        <ui>
          <menubar name="MenuBar">
            <menu name="SearchMenu" action="Search">
              <placeholder name="SearchOps_8">
                <menuitem name="SearchGoToDefinitionMenu" action="SearchGoToDefinition"/>
                <menuitem name="SearchGoToEnclosingMethodMenu" action="SearchGoToEnclosingMethod"/>
                <menuitem name="SearchGoBackMenu" action="SearchGoBack"/>
                <menuitem name="SearchGoForwardMenu" action="SearchGoForward"/>
                <separator/>
                <menuitem name="SearchNextErrorMenu" action="SearchNextError"/>
                <menuitem name="SearchPrevErrorMenu" action="SearchPrevError"/>
                <separator/>
                <menuitem name="SearchAutocompleteMenu" action="SearchAutocomplete"/>
              </placeholder>
            </menu>
            <placeholder name="ExtraMenu_1">
              <menu name="ProjectMenu" action="Project">
                <menuitem name="ProjectBuildMenu" action="ProjectBuild"/>
                <menuitem name="ProjectRunMenu" action="ProjectRun"/>
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

        // Tooltips        
        tip = new Tooltip(window);
        autocomplete = new AutocompleteDialog(window);

        // Output pane
        output_buffer = new Gtk.TextBuffer(null);

        error_tag = output_buffer.create_tag("error", "foreground", "#c00");
        italic_tag = output_buffer.create_tag("italic", "style", Pango.Style.OBLIQUE);
        bold_tag = output_buffer.create_tag("bold", "weight", Pango.Weight.BOLD);
        highlight_tag = output_buffer.create_tag("highlight", "foreground", "black", "background", 
                                                 "#abd");
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

        // Run pane
        run_terminal = new Vte.Terminal();
        run_terminal.child_exited += on_run_child_exit;
        child_process_running = false;
        
        run_pane = new Gtk.ScrolledWindow(null, null);
        run_pane.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC);
        run_pane.add(run_terminal);
        run_pane.show_all();
        
        panel.add_item_with_stock_icon(run_pane, "Run", Gtk.STOCK_EXECUTE);     
        
        // Enclosing class in statusbar
        old_cursor_offset = 0;
        
        // Toolbar menu
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
        
        go_to_enclosing_method_or_class_menu_item = (Gtk.MenuItem) manager.get_widget(
            "/MenuBar/SearchMenu/SearchOps_8/SearchGoToEnclosingMethodMenu");
        assert(go_to_enclosing_method_or_class_menu_item != null);
        
        go_back_menu_item = (Gtk.MenuItem) manager.get_widget(
            "/MenuBar/SearchMenu/SearchOps_8/SearchGoBackMenu");
        assert(go_back_menu_item != null);
        
        go_forward_menu_item = (Gtk.MenuItem) manager.get_widget(
            "/MenuBar/SearchMenu/SearchOps_8/SearchGoForwardMenu");
        assert(go_forward_menu_item != null);

        next_error_menu_item = (Gtk.MenuItem) manager.get_widget(
            "/MenuBar/SearchMenu/SearchOps_8/SearchNextErrorMenu");
        assert(next_error_menu_item != null);
        
        prev_error_menu_item = (Gtk.MenuItem) manager.get_widget(
            "/MenuBar/SearchMenu/SearchOps_8/SearchPrevErrorMenu");
        assert(prev_error_menu_item != null);
        
        display_tooltip_menu_item = (Gtk.MenuItem) manager.get_widget(
            "/MenuBar/SearchMenu/SearchOps_8/SearchAutocompleteMenu");
        assert(display_tooltip_menu_item != null);
        
        build_menu_item = (Gtk.MenuItem) manager.get_widget(
            "/MenuBar/ExtraMenu_1/ProjectMenu/ProjectBuildMenu");
        assert(build_menu_item != null);
        
        run_menu_item = (Gtk.MenuItem) manager.get_widget(
            "/MenuBar/ExtraMenu_1/ProjectMenu/ProjectRunMenu");
        assert(run_menu_item != null);

        init_error_regex();

        add_signal(window, "tab-added", (Callback) tab_added_callback);
        add_signal(window, "tab-removed", (Callback) tab_removed_callback);
    }

    ~Instance() {
        foreach (Pair<GLib.Object, ulong> pair in signal_handler_list) {
            if (SignalHandler.is_connected(pair.first, pair.second))
                SignalHandler.disconnect(pair.first, pair.second);
        }
    }
    
    void add_signal(GLib.Object instance, string signal_name, GLib.Callback cb, 
                    bool after = false) {
        ulong id;
        if (!after)
            id = Signal.connect(instance, signal_name, cb, this);
        else id = Signal.connect_after(instance, signal_name, cb, this);
        signal_handler_list.append(new Pair<GLib.Object, ulong>(instance, id));
    }

    static void tab_added_callback(Gedit.Window window, Gedit.Tab tab, Instance instance) {
        Gedit.Document document = tab.get_document();
        instance.add_signal(document, "saved", (Callback) all_save_callback);

        // Hook up this particular tab's view with tooltips
        Gedit.View tab_view = tab.get_view();
        instance.add_signal(tab_view, "key-press-event", (Callback) key_press_callback);
        
        Gtk.Widget widget = tab_view.get_parent();
        Gtk.ScrolledWindow scrolled_window = widget as Gtk.ScrolledWindow;
        assert(scrolled_window != null);
        
        Gtk.Adjustment vert_adjust = scrolled_window.get_vadjustment();
        instance.add_signal(vert_adjust, "value-changed", (Callback) scrolled_callback);

        instance.add_signal(document, "insert-text", (Callback) text_inserted_callback, true);
        instance.add_signal(document, "delete-range", (Callback) text_deleted_callback, true);
        instance.add_signal(document, "cursor-moved", (Callback) cursor_moved_callback, true);
        
        instance.add_signal(tab_view, "focus-out-event", (Callback) focus_off_view_callback);
        instance.add_signal(tab_view, "button-press-event", (Callback) button_press_callback);
    }

    static void tab_removed_callback(Gedit.Window window, Gedit.Tab tab, Instance instance) {
        Gedit.Document document = tab.get_document();

        if (document.get_modified()) {
            // We're closing a document without saving changes.  Reparse the symbol tree
            // from the source file on disk (if the file exists on disk).
            string path = document_filename(document);
            if (path != null && FileUtils.test(path, FileTest.EXISTS))
                Program.update_any(path, null);
        }
    }
    
    static void scrolled_callback(Gtk.Adjustment adjust, Instance instance) {
        instance.tip.hide();
        instance.autocomplete.hide();
    }

    static bool key_press_callback(Gedit.View view, Gdk.EventKey key, Instance instance) {
        bool handled = false; 
        
        // These will always catch, even with alt and ctrl modifiers
        switch(key.keyval) {
            case 0xff1b: // escape
                if (instance.autocomplete.is_visible())
                    instance.autocomplete.hide();
                else
                    instance.tip.hide();
                handled = true;
                break;
            case 0xff52: // up arrow
                if (instance.autocomplete.is_visible()) {
                    instance.autocomplete.select_previous();
                    handled = true;
                }
                break;
            case 0xff54: // down arrow
                if (instance.autocomplete.is_visible()) {
                    instance.autocomplete.select_next();
                    handled = true;
                }
                break;
            case 0xff50: // home
                if (instance.autocomplete.is_visible()) {
                    instance.autocomplete.select_first_cell();
                    handled = true;
                }
                break;
            case 0xff57: // end
                if (instance.autocomplete.is_visible()) {
                    instance.autocomplete.select_last_cell();
                    handled = true;
                }
                break;
            case 0xff55: // page up
                if (instance.autocomplete.is_visible()) {
                    instance.autocomplete.page_up();
                    handled = true;
                }
                break;
            case 0xff56: // page down
                if (instance.autocomplete.is_visible()) {
                    instance.autocomplete.page_down();
                    handled = true;
                }
                break;
            case 0xff0d: // return
                if (instance.autocomplete.is_visible()) {
                    instance.autocomplete.select_item();
                    handled = true;
                }
                break;
            default:
                break;
        }
        
        return handled;
    }

    static bool focus_off_view_callback(Gedit.View view, Gdk.EventFocus focus, Instance instance) {
        instance.tip.hide();
        instance.autocomplete.hide();
        
        // Make sure to display the new enclosing class when switching tabs
        instance.old_cursor_offset = 0;
        instance.update_status_bar();
        
        // Let other handlers catch this event as well
        return false;
    }

    static void text_inserted_callback(Gedit.Document doc, Gtk.TextIter iter, string text,
                                       int length, Instance instance) {
        if (instance.autocomplete.is_visible()) {
            if (text.get_char().isspace())
                instance.autocomplete.hide();
            else
                instance.display_autocomplete();

        }

        if (instance.tip.is_visible()) {
            if (text == ")" || text == "(") {
                instance.tip.hide();
                instance.autocomplete.hide();
                instance.display_tooltip();
            } 
        } 
    }

    static void text_deleted_callback(Gedit.Document doc, Gtk.TextIter start, Gtk.TextIter end,
                                      Instance instance) {
        if (instance.tip.is_visible()) {
            string line = instance.tip.get_method_line();
            if (!line.contains(instance.tip.get_method_name() + "("))
                instance.tip.hide(); 
        }
        
        if (instance.autocomplete.is_visible()) {
            instance.autocomplete.hide();
            instance.on_display_tooltip_or_autocomplete();
        }
    }
    
    static void cursor_moved_callback(Gedit.Document doc, Instance instance) {
        instance.update_status_bar();
    }

    static bool button_press_callback(Gedit.View view, Gdk.EventButton event, Instance instance) {
        instance.tip.hide();
        instance.autocomplete.hide();

        // Let other handlers catch this event as well
        return false;
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
                    generate_error_history(last_program_to_build);
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
        
        if (filename == null)
            return;
        
        Program.rescan_build_root(filename);

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
            return;        // TODO: report error
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

    void jump_to_document_error(Gtk.TextIter iter, ErrorInfo info, Program program) {
        int line_number = info.start_line.to_int();
        Destination dest;
        if (info.start_char == null)
            dest = new LineNumber(line_number - 1);
        else
            dest = new LineCharRange(line_number - 1, info.start_char.to_int() - 1,
                                     info.end_line.to_int() - 1, info.end_char.to_int());

        if (Path.is_absolute(info.filename)) {
            jump(info.filename, dest);
        } else {
            string filename = program.get_path_for_filename(info.filename);
             if (filename == null)
                return;
            jump(filename, dest);
        }
    }

////////////////////////////////////////////////////////////
//                   Jump to Definition                   //
////////////////////////////////////////////////////////////

    void add_mark_at_insert_to_history() {
        Gedit.Document doc = window.get_active_document();
        Gtk.TextIter insert = get_insert_iter(doc);
            
        // Don't add a mark to history if the most recent mark is on the same line
        if (history.size > 0) {
            Gtk.TextMark old_mark = history.get(history.size - 1);
            Gedit.Document old_doc = (Gedit.Document) old_mark.get_buffer();
  
            if (old_doc == doc) {
                Gtk.TextIter old_iter;
                old_doc.get_iter_at_mark(out old_iter, old_mark);
                if (old_iter.get_line() == insert.get_line())
                    return;
            }
        }

        Gtk.TextMark mark = doc.create_mark(null, insert, false);
        history.add(mark);
        if (history.size > MAX_HISTORY)
            history.remove_at(0);
        history_index = history.size; // always set the current index to be at the top
    }
    
    void add_insert_cursor_to_history() {
        // Make sure the current index is the last element
        while (history.size > 0 && history.size > history_index)
            history.remove_at(history.size - 1);

        add_mark_at_insert_to_history();
        browsing_history = false;
    }
    
    void get_buffer_str_and_pos(string filename, out weak string source, out int pos) {
        Program program = Program.find_containing(filename, true);

        // Reparse any modified documents in this program.
        foreach (Gedit.Document d in Gedit.App.get_default().get_documents())
            if (d.get_modified()) {
                string path = document_filename(d);
                if (path != null)
                    program.update(path, buffer_contents(d));
            }
        
        Gedit.Document document = window.get_active_document();
        source = buffer_contents(document);
        Gtk.TextIter insert = get_insert_iter(document);
        pos = insert.get_offset();
    }

    void on_go_to_definition() {
        string? filename = active_filename();
        if (filename == null || !Program.is_vala(filename))
            return;

        Program program = Program.find_containing(filename, true);
        
        if (program.is_parsing()) {
            program.parsed_file += update_parse_dialog;
            program.system_parse_complete += jump_to_symbol_definition;
        } else jump_to_symbol_definition();
    }

    void jump_to_symbol_definition() {
        string? filename = active_filename();
        if (filename == null)
            return;
            
        weak string source;
        int pos;
        get_buffer_str_and_pos(filename, out source, out pos);

        bool in_new;
        CompoundName name = new Parser().name_at(source, pos, out in_new); 
        if (name == null)
            return;

        Program program = Program.find_containing(filename);
        SourceFile sf = program.find_source(filename);
        Symbol? sym = sf.resolve(name, pos, in_new);
        if (sym == null)
            return;
            
        add_insert_cursor_to_history();

        SourceFile dest = sym.source;
        if (sym.name == null)
            jump(dest.filename, new CharRange(sym.start, sym.start + (int) name.to_string().length));
        else
            jump(dest.filename, new CharRange(sym.start, sym.start + (int) sym.name.length));
    }
    
    void on_go_to_enclosing_method_or_class() {
        string? filename = active_filename();
        if (filename == null || !Program.is_vala(filename))
            return;

        weak string source;
        int pos;
        get_buffer_str_and_pos(filename, out source, out pos);

        ScanScope? scan_scope = new Parser().find_enclosing_scope(source, pos, false);
        if (scan_scope == null)
            return;
        
        add_insert_cursor_to_history();
        
        jump(filename, new CharRange(scan_scope.start_pos, scan_scope.end_pos));
    }

    void on_go_back() {
        if (history.size == 0)
            return;

        // Preserve place in history
        if (history_index == history.size && !browsing_history) {
            add_mark_at_insert_to_history();
            browsing_history = true;
        }
        
        if (history_index <= 1)
            return;

        --history_index;
        scroll_to_history_index();
    }
    
    void on_go_forward() {
        if (history.size == 0 || history_index >= history.size)
            return;

        ++history_index;
        scroll_to_history_index();
    }

    void scroll_to_history_index() {
        Gtk.TextMark mark = history.get(history_index - 1);
        assert(!mark.get_deleted());
        
        Gedit.Document buffer = (Gedit.Document) mark.get_buffer();
        Gtk.TextIter iter;
        buffer.get_iter_at_mark(out iter, mark);
        buffer.place_cursor(iter);
        
        Gedit.Tab tab = Gedit.Tab.get_from_document(buffer);
        Gedit.Window window = (Gedit.Window) tab.get_toplevel();
        window.set_active_tab(tab);
        window.present();

        scroll_tab_to_iter(tab, iter);
    }

    bool can_go_back() {
        if (history.size == 0 || history_index <= 1)
            return false;

        // -2 because history_index is not 0-based (it is 1-based), and we need the previous element
        Gtk.TextMark mark = history.get(history_index - 2);

        return !mark.get_deleted();
    }

    bool can_go_forward() {
        if (history.size == 0 || history_index >= history.size)
            return false;

        Gtk.TextMark mark = history.get(history_index);
        return !mark.get_deleted();
    }

////////////////////////////////////////////////////////////
//                      Jump to Error                     //
////////////////////////////////////////////////////////////

    void update_error_history_index(ErrorList program_errors, ErrorInfo info) {
        program_errors.error_index = -1;
        foreach (ErrorPair pair in program_errors.errors) {
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
        update_error_history_index(last_program_to_build.error_list, info);

        return true;
    }

    string active_filename() {
        Gedit.Document document = window.get_active_document();
        return document == null ? null : document_filename(document);
    }
    
    void clear_error_list(Gee.ArrayList<ErrorPair> error_list) {
        if (error_list == null || error_list.size == 0)
            return;

        // Before clearing the ArrayList, clean up the TextMarks stored in the buffers
        foreach (ErrorPair pair in error_list) {
            Gtk.TextMark mark = pair.document_pane_error;
            Gtk.TextBuffer buffer = mark.get_buffer();
            buffer.delete_mark(mark);

            mark = pair.build_pane_error;
            buffer = mark.get_buffer();
            buffer.delete_mark(mark);    
        }
       
        error_list.clear();
    }

    void generate_error_history(Program program) {
        if (program.error_list == null)
            program.error_list = new ErrorList();
        clear_error_list(program.error_list.errors);

        // Starting at the first line, search for errors downward
        Gtk.TextIter iter = get_insert_iter(output_buffer);
        iter.set_line(0);
        ErrorInfo einfo;
        program.error_list.error_index = -1;
        bool end_of_buffer = false;
        
        while (!end_of_buffer) {
            // Check the current line for errors
            einfo = error_info(iter);
            if (einfo != null) {
                Gedit.Document document = window.get_active_document();
                Gtk.TextIter document_iter;
                document.get_iter_at_line(out document_iter, einfo.start_line.to_int());
              
                Gtk.TextMark doc_mark = document.create_mark(null, document_iter, false);
                Gtk.TextMark build_mark = output_buffer.create_mark(null, iter, false);
                
                ErrorPair pair = new ErrorPair(doc_mark, build_mark, einfo);
                program.error_list.errors.add(pair);
            }                
            
            end_of_buffer = !iter.forward_line();
        }
    }

    Instance? find_build_instance(string cur_top_directory) {
        foreach (Instance inst in plugin.instances) {
            if (inst.last_program_to_build != null && 
                inst.last_program_to_build.get_top_directory() == cur_top_directory) {
                    return inst;
                }
        }
        
        return null;
    }
    
    void move_output_mark_into_focus(Gtk.TextMark mark) {
        Gtk.TextBuffer output = mark.get_buffer();
        Gtk.TextIter iter;
        output.get_iter_at_mark(out iter, mark);
        output_view.scroll_to_iter(iter, 0.25, true, 0.0, 0.0);
        
        show_output_pane();
        tag_text_buffer_line(output_buffer, highlight_tag, iter);
    }

    void move_to_error(Program program) {
        ErrorPair pair = program.error_list.errors[program.error_list.error_index];

        Gtk.TextBuffer document = pair.document_pane_error.get_buffer();
        Gtk.TextIter doc_iter;
        document.get_iter_at_mark(out doc_iter, pair.document_pane_error);
        
        Instance target = find_build_instance(program.get_top_directory());
        if (target == null)
            return;

        jump_to_document_error(doc_iter, pair.error_info, program);
        target.move_output_mark_into_focus(pair.build_pane_error);
    }
    
    Program get_active_document_program() {
        string filename = active_filename();
        return Program.find_containing(filename);
    }

    bool active_document_is_valid_vala_file() {
        string filename = active_filename();
        return filename != null && Program.is_vala(filename);
    }
        
    void on_next_error() {
        if (active_filename() == null)
            return;
    
        Program program = get_active_document_program();
        
        if (program.error_list == null || program.error_list.errors.size == 0)
            return;
    
        if (program.error_list.error_index < program.error_list.errors.size - 1)
            ++program.error_list.error_index;
        
        move_to_error(program);
    }

    void on_prev_error() {
        if (active_filename() == null)
            return;
    
        Program program = get_active_document_program();
        
        if (program.error_list == null || program.error_list.errors.size == 0)
            return;
    
        if (program.error_list.error_index > 0)
            --program.error_list.error_index;
        
        move_to_error(program);
    }

////////////////////////////////////////////////////////////
//                      Run Command                       //
////////////////////////////////////////////////////////////

    void on_run() {
        if (active_filename() == null || child_process_running)
            return;

        string filename = get_active_document_filename();
        Program.rescan_build_root(filename);
        
        Program program = get_active_document_program();
        program.reparse_makefile();
        string binary_path = program.get_binary_run_path();
        
        if (binary_path == null || !program.get_binary_is_executable())
            return;

        if (!GLib.FileUtils.test(binary_path, GLib.FileTest.EXISTS)) {
            show_error_dialog("\"" + binary_path + "\" was not found. Try rebuilding. ");
            return;
        }
        
        if (!GLib.FileUtils.test(binary_path, GLib.FileTest.IS_EXECUTABLE)) {
            show_error_dialog("\"" + binary_path + "\" is not an executable file! ");
            return;
        }

        string[] args = { binary_path };
        
        int pid = run_terminal.fork_command(binary_path, args, null, Path.get_dirname(binary_path),
                                            false, false, false);

        if (pid == -1) {
            show_error_dialog("There was a problem running \"" + binary_path + "\"");
            return;
        }

        run_terminal.reset(true, true);
        run_pane.show();
        Gedit.Panel panel = window.get_bottom_panel();
        panel.activate_item(run_pane);
        panel.show();
        
        child_process_running = true;
    }

    void on_run_child_exit() {
        run_terminal.feed("\r\nThe program exited.\r\n", -1);
        child_process_running = false;
    }

////////////////////////////////////////////////////////////
//                  Progress bar update                   //
////////////////////////////////////////////////////////////

    void update_parse_dialog(double percentage) {
        if (percentage == 1.0) {
            if (parsing_dialog != null) {
                parsing_dialog.close();
                parsing_dialog = null;
            }
            return;
        }

        if (parsing_dialog == null)
            parsing_dialog = new ProgressBarDialog(window, "Parsing Vala files");

        parsing_dialog.set_percentage(percentage);
    }

////////////////////////////////////////////////////////////
//                   Status bar update                    //
////////////////////////////////////////////////////////////

    bool cursor_moved_outside_old_scope(string buffer, int new_cursor_offset) {
        int begin_offset;
        int length;

        if (new_cursor_offset < old_cursor_offset) {
            begin_offset = new_cursor_offset;
            length = old_cursor_offset - new_cursor_offset;
        } else {
            begin_offset = old_cursor_offset;
            length = new_cursor_offset - old_cursor_offset;
        }
        
        weak string begin_string = buffer.offset(begin_offset);

        for (int i = 0; i < length; ++i) {
            unichar c = begin_string.get_char();
            if (c == '{' || c == '}') {
                old_cursor_offset = new_cursor_offset;
                return true;
            }
            begin_string = begin_string.next_char();
        }
        
        return false;
    }

    void update_status_bar() {
        string? filename = active_filename();
        if (filename == null || !Program.is_vala(filename))
            return;

        Gedit.Document document = window.get_active_document();
        weak string source = buffer_contents(document);
        Gtk.TextIter insert = get_insert_iter(document);
        int pos = insert.get_offset();
        
        // Don't reparse if the cursor hasn't moved past a '{' or a '}'
        if (!cursor_moved_outside_old_scope(source, pos))
            return;

        ScanScope? scan_scope = new Parser().find_enclosing_scope(source, pos, true);
        string class_name;
        if (scan_scope == null)
            class_name = "";
        else
            class_name = source.substring(scan_scope.start_pos, 
                                          scan_scope.end_pos - scan_scope.start_pos);
        
        Gtk.Statusbar bar = (Gtk.Statusbar) window.get_statusbar();
        bar.push(bar.get_context_id("Valencia"), class_name);
    }

////////////////////////////////////////////////////////////
//                 Tooltip/Autocomplete                   //
////////////////////////////////////////////////////////////

    void on_display_tooltip_or_autocomplete() {
        string? filename = active_filename();
        if (filename == null || !Program.is_vala(filename))
            return;

        Program program = Program.find_containing(filename, true);
        
        if (program.is_parsing()) {
            program.parsed_file += update_parse_dialog;
            program.system_parse_complete += display_tooltip_or_autocomplete;
        } else display_tooltip_or_autocomplete();
    }

    void display_tooltip_or_autocomplete() {
        Method method;
        CompoundName method_name;
        int method_pos, cursor_pos;
        CompoundName name_at_cursor;
        get_tooltip_and_autocomplete_info(out method, out method_name, out method_pos, 
                                          out cursor_pos, out name_at_cursor);

        if (method != null)
            tip.show(method_name.to_string(), " " + method.to_string() + " ", method_pos);  
        else {
            if (name_at_cursor == null)
                name_at_cursor = new SimpleName("");
            
            string? filename = active_filename();
            Program program = Program.find_containing(filename);
            SourceFile sf = program.find_source(filename);
            
            if (cursor_is_inside_word())
                return;
            
            SymbolSet symbol_set = sf.resolve_prefix(name_at_cursor, cursor_pos);
            autocomplete.show(symbol_set);
        }
    }

    void display_tooltip() {
        Method method;
        CompoundName method_name;
        int method_pos, cursor_pos;
        CompoundName name_at_cursor;
        get_tooltip_and_autocomplete_info(out method, out method_name, out method_pos, 
                                          out cursor_pos, out name_at_cursor);

        if (method != null)
            tip.show(method_name.to_string(), " " + method.to_string() + " ", method_pos);  
    }

    void display_autocomplete() {
        Method method;
        CompoundName method_name;
        int method_pos, cursor_pos;
        CompoundName name_at_cursor;
        get_tooltip_and_autocomplete_info(out method, out method_name, out method_pos, 
                                          out cursor_pos, out name_at_cursor);

        if (name_at_cursor == null)
            name_at_cursor = new SimpleName("");

        string? filename = active_filename();
        Program program = Program.find_containing(filename);
        SourceFile sf = program.find_source(filename);

        if (cursor_is_inside_word())
            return;

        SymbolSet symbol_set = sf.resolve_prefix(name_at_cursor, cursor_pos);
        autocomplete.show(symbol_set);
    }

    void get_tooltip_and_autocomplete_info(out Method? method, out CompoundName? name,
                                           out int method_pos, out int cursor_pos,
                                           out CompoundName? name_at_cursor) {
        string? filename = active_filename();
        weak string source;
        get_buffer_str_and_pos(filename, out source, out cursor_pos); 

        bool in_new;
        name = new Parser().method_at(source, cursor_pos, out method_pos, out name_at_cursor, out in_new);

        Program program = Program.find_containing(filename);
        SourceFile sf = program.find_source(filename);
        // The sourcefile may be null if the file is a vala file but hasn't been saved to disk
        if (sf == null)
            return;

        // Give the method tooltip precedence over autocomplete
        method = null;
        if (name != null && (!tip.is_visible() || cursor_is_inside_different_function(method_pos))) {
            Symbol? sym = sf.resolve(name, cursor_pos, in_new);
            if (sym != null)
                method = sym as Method; 
        }
    }

    bool cursor_is_inside_different_function(int method_pos) {
        Gtk.TextIter begin_iter = tip.get_iter_at_method();

        Gedit.Document document = window.get_active_document();
        Gtk.TextIter end_iter;
        document.get_iter_at_offset(out end_iter, method_pos);

        if (begin_iter.get_offset() > end_iter.get_offset()) {
            Gtk.TextIter temp;
            temp = begin_iter; 
            begin_iter = end_iter;
            end_iter = temp;
        }

        // Make sure the last character is a '(', since the method_pos offset will always be the
        // character before the '(' in a function call
        end_iter.forward_char();

        int left_parens = 0;
        begin_iter.forward_char();
        while (begin_iter.get_offset() <= end_iter.get_offset()) {
            unichar c = begin_iter.get_char();
            if (c == ')') {
                if (--left_parens != 0)
                    return true;
            } else if (c == '(') {
                ++left_parens;
            }
            
            begin_iter.forward_char();
        }
            
        return left_parens != 0;
    }

    bool cursor_is_inside_word() {
        Gedit.Document document = window.get_active_document();
        Gtk.TextMark insert_mark = document.get_insert();
        Gtk.TextIter insert_iter;
        document.get_iter_at_mark(out insert_iter, insert_mark);
        
        return insert_iter.get_char().isalnum();
    }

////////////////////////////////////////////////////////////
//           Menu activation and plugin class             //
////////////////////////////////////////////////////////////

    bool errors_exist() {
        Program program = get_active_document_program();
        return program.error_list != null && program.error_list.errors.size != 0;
    }

    bool program_exists_for_active_document() {
        string filename = active_filename();
        return Program.null_find_containing(filename) != null;
    }

    void on_search_menu_activated() {
        bool definition_item_sensitive = active_document_is_valid_vala_file();
        go_to_definition_menu_item.set_sensitive(definition_item_sensitive);
        go_back_menu_item.set_sensitive(can_go_back());
        go_forward_menu_item.set_sensitive(can_go_forward());

        bool activate_error_search = active_filename() != null && 
                                     program_exists_for_active_document() && errors_exist();

        next_error_menu_item.set_sensitive(activate_error_search);
        prev_error_menu_item.set_sensitive(activate_error_search);
        
        display_tooltip_menu_item.set_sensitive(definition_item_sensitive);
    }

    void on_project_menu_activated() {
        bool active_file_not_null = active_filename() != null;
        build_menu_item.set_sensitive(active_file_not_null);

        // Make sure the program for the file exists first, otherwise disable the run button        
        if (active_file_not_null && program_exists_for_active_document()) {
            Program program = get_active_document_program();
            program.reparse_makefile();
            string binary_path = program.get_binary_run_path();
            
            run_menu_item.set_sensitive(!child_process_running && binary_path != null &&
                                        program.get_binary_is_executable());
        } else {
            run_menu_item.set_sensitive(false);
        }
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

