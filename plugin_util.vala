/* Copyright 2009 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

using Gee; 
using Valencia;

class AutocompleteDialog : Object {
    weak Gedit.Window parent;
    Gtk.Window window;
    ListViewString list;
    bool visible;
    string partial_name;
    bool inserting_text;

    public AutocompleteDialog(Gedit.Window parent_win) {
        parent = parent_win;
        visible = false;
        inserting_text = false;
        list = new ListViewString(Gtk.TreeViewColumnSizing.AUTOSIZE, 100);
        list.row_activated += select_item;

        window = new Gtk.Window(Gtk.WindowType.POPUP); 
        window.add(list.scrolled_window);
        window.set_destroy_with_parent(true);
        window.set_default_size(200, 1); 
        window.set_resizable(true);
        window.set_title("");
        window.set_border_width(1);
      
        window.show_all();
        window.hide();

        Signal.connect(window, "expose-event", (Callback) draw_callback, this);
    }

    static bool draw_callback(Gtk.Window window, Gdk.EventExpose event, AutocompleteDialog dialog) {
        Gtk.paint_flat_box(dialog.window.style, dialog.window.window, 
                           Gtk.StateType.NORMAL, Gtk.ShadowType.OUT, 
                           null, dialog.window, "tooltip",
                           dialog.window.allocation.x, dialog.window.allocation.y,
                           dialog.window.allocation.width, dialog.window.allocation.height);

        dialog.list.scrolled_window.expose_event(event);

        return true;
    }

    unowned string? get_completion_target(Gtk.TextBuffer buffer) {
        Gtk.TextIter start = get_insert_iter(buffer);
        Gtk.TextIter end = start;
        
        while (true) {
            start.backward_char();
            unichar c = start.get_char();
            if (!c.isalnum() && c != '.' && c != '_')
                break;
        }
        // Only include characters in the ID name
        start.forward_char();
        
        if (start.get_offset() == end.get_offset())
            return null;
        
        return start.get_slice(end);
    }
    
    string strip_completed_classnames(string list_name, string completion_target) {
        string[] classnames = completion_target.split(".");
        int names = classnames.length;
        // If the last classname is not explicitly part of the class qualification, then it 
        // should not be removed from the completion suggestion's name
        if (!completion_target.has_suffix("."))
            --names;
            
        for (int i = 0; i < names; ++i) {
            weak string name = classnames[i];

            // If the name doesn't contain the current classname, it may be a namespace name that
            // isn't part of the list_name string - we shouldn't stop the comparison early
            if (list_name.contains(name)) {
                // Add one to the offset of a string to account for the "."
                long offset = name.length;
                if (offset > 0)
                    ++offset;
                list_name = list_name.offset(offset);
            }
        }

        return list_name;
    }

    string parse_single_symbol(Symbol symbol, string? completion_target, bool constructor) {
        string list_name = "";
        
        if (constructor) {
            // Get the fully-qualified constructor name
            Constructor c = symbol as Constructor;
            assert(c != null);

            list_name = c.parent.to_string();
            
            if (c.name != null)
                list_name += "." + c.name;
            list_name += "()";

            // If the user hasn't typed anything or if either the completion string or this 
            // constructor is not qualified, keep the original name
            if (completion_target != null && completion_target.contains(".") 
                && list_name.contains("."))
                list_name = strip_completed_classnames(list_name, completion_target);
            
        } else {
            list_name = symbol.name;
            if (symbol is Method && !(symbol is Delegate))
                list_name = symbol.name + "()";
        }
        
        return list_name;
    }

    string[]? parse_symbol_names(HashSet<Symbol>? symbols) {
        if (symbols == null)
            return null;
            
        string[] list = new string[symbols.size];

        // If the first element is a constructor, all elements will be constructors
        Iterator<Symbol> iter = symbols.iterator();
        iter.next();
        bool constructor = iter.get() is Constructor;

        // match the extent of what the user has already typed with named constructors
        string? completion_target = null;
        if (constructor) {          
            completion_target = get_completion_target(parent.get_active_document());
        }

        int i = 0;
        foreach (Symbol symbol in symbols) {
            list[i] = parse_single_symbol(symbol, completion_target, constructor);
            ++i;
        }
            
        qsort(list, symbols.size, sizeof(string), compare_string);
        return list;
    }

    public void show(SymbolSet symbol_set) {
        if (inserting_text)
            return;

        list.clear();
        visible = true;
        partial_name = symbol_set.get_name();

       weak HashSet<Symbol>? symbols = symbol_set.get_symbols();
       string[]? symbol_strings = parse_symbol_names(symbols);

        if (symbol_strings != null) {
            foreach (string s in symbol_strings) {
                list.append(s);
            }
        } else {
            hide();
            return;
        }

        // TODO: this must be updated to account for font size changes when adding ticket #560        
        int size = list.size();
        if (size > 6) {
            list.set_vscrollbar_policy(Gtk.PolicyType.AUTOMATIC);
            window.resize(200, 140);
        } else {
            list.set_vscrollbar_policy(Gtk.PolicyType.NEVER);
            window.resize(200, size * 23);
        }

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

    public void select_first_cell() {
        list.select_first_cell();
    }

    public void select_last_cell() {
        list.select_last_cell();
    }

    public void select_previous() {
        list.select_previous();
    }

    public void select_next() {
        list.select_next();
    }

    public void page_up() {
        list.page_up();
    }

    public void page_down() {
        list.page_down();
    }

    public void select_item() {
        string selection = list.get_selected_item();
        Gedit.Document buffer = parent.get_active_document();

        // delete the whole string to be autocompleted and replace it (the case may not match)
        Gtk.TextIter start = get_insert_iter(buffer);
        while (true) {
            if (!start.backward_char())
                break;
            unichar c = start.get_char();
            if (!c.isalnum() && c != '_')
                break;
        }
        // don't include the nonalphanumeric character
        start.forward_char();

        Gtk.TextIter end = start;
        while (true) {
            unichar c = end.get_char();
            if (c == '(') {
                end.forward_char();
                break;
            }
            if (!c.isalnum() && c != '_' && c != '.')
                break;
            if (!end.forward_char())
                break;
        }

        // Text insertion/deletion signals have been linked to updating the autocomplete dialog -
        // we don't want to do that if we're already inserting text.
        inserting_text = true;
        buffer.delete(start, end);

        long offset = selection.has_suffix(")") ? 1 : 0;
        buffer.insert_at_cursor(selection, (int) (selection.length - offset));
        inserting_text = false;

        hide();
    }
}

class ProjectSettingsDialog : Object {
    Gtk.Dialog dialog;
    Gtk.Entry build_entry;
    Gtk.Entry clean_entry;

    string build_command;
    string clean_command;

    public signal void settings_changed(string new_build_command, string new_clean_command);

    public ProjectSettingsDialog(Gtk.Window parent_win) {
        // Window creation
        Gtk.Label build_command_label = new Gtk.Label("Build command:");
        build_entry = new Gtk.Entry();
        build_entry.activate += on_entry_activated;
        
        Gtk.Alignment align_build_label = new Gtk.Alignment(0.0f, 0.5f, 0.0f, 0.0f);
        align_build_label.add(build_command_label);

        Gtk.Label clean_command_label = new Gtk.Label("Clean command:");
        clean_entry = new Gtk.Entry();
        clean_entry.activate += on_entry_activated;
        
        Gtk.Alignment align_clean_label = new Gtk.Alignment(0.0f, 0.5f, 0.0f, 0.0f);
        align_clean_label.add(clean_command_label);

        Gtk.Table table = new Gtk.Table(2, 2, false);
        table.set_col_spacings(12);
        table.set_row_spacings(6);
        
        table.attach(align_build_label, 0, 1, 0, 1, 
                     Gtk.AttachOptions.FILL, Gtk.AttachOptions.FILL, 0, 0);
        table.attach(align_clean_label, 0, 1, 1, 2, 
                     Gtk.AttachOptions.FILL, Gtk.AttachOptions.FILL, 0, 0);
        table.attach(build_entry, 1, 2, 0, 1, Gtk.AttachOptions.FILL | Gtk.AttachOptions.EXPAND, 
                     Gtk.AttachOptions.FILL, 0, 0);
        table.attach(clean_entry, 1, 2, 1, 2, Gtk.AttachOptions.FILL | Gtk.AttachOptions.EXPAND, 
                     Gtk.AttachOptions.FILL, 0, 0);
                     
        Gtk.Alignment alignment_box = new Gtk.Alignment(0.5f, 0.5f, 1.0f, 1.0f);
        alignment_box.set_padding(5, 6, 6, 5);
        alignment_box.add(table);

        dialog = new Gtk.Dialog.with_buttons("Settings", parent_win, Gtk.DialogFlags.MODAL |
                                             Gtk.DialogFlags.DESTROY_WITH_PARENT, 
                                             Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL, 
                                             Gtk.STOCK_OK, Gtk.ResponseType.OK, null);
        dialog.set_default_response(Gtk.ResponseType.OK);
        dialog.set_default_size(350, 10);
        dialog.delete_event += dialog.hide_on_delete;

        dialog.vbox.pack_start(alignment_box, false, false, 0);
        // Make all children visible by default
        dialog.vbox.show_all();
    }

    void on_entry_activated() {
        dialog.response(Gtk.ResponseType.OK);
    }

    void load_settings(string active_filename) {
        Program program = Program.find_containing(active_filename);
            
        build_command = program.config_file.get_build_command();
        if (build_command == null)
            build_command = ConfigurationFile.default_build_command;

        clean_command = program.config_file.get_clean_command();
        if (clean_command == null)
            clean_command = ConfigurationFile.default_clean_command;
    }

    public void show(string active_filename) {
        // On first-time startup, look for a .valencia file that may have a stored build command
        load_settings(active_filename);

        build_entry.set_text(build_command);
        clean_entry.set_text(clean_command);

        dialog.set_focus(build_entry);
        int result = dialog.run();
        switch (result) {
            case Gtk.ResponseType.OK:
                save_and_close();
                break;
            default:
                hide();
                break;
        }
    }

    void hide() {
        dialog.hide();
    }

    void save_and_close() {
        string new_build_command = build_entry.get_text();
        string new_clean_command = clean_entry.get_text();

        bool changed = false;
        if (new_build_command != build_command && new_build_command != "") {
                build_command = new_build_command;
                changed = true;
        }

        if (new_clean_command != clean_command && new_clean_command != "") {
                clean_command = new_clean_command;
                changed = true;
        }        
       
        if (changed)
            settings_changed(build_command, clean_command);

        hide();
    }

}

class SymbolBrowser {
    weak Instance parent;

    Gtk.Entry find_entry;
    ListViewString list;
    Gtk.VBox symbol_vbox;
    
    bool visible;

    public SymbolBrowser(Instance parent) {
        this.parent = parent;

        find_entry = new Gtk.Entry();
        find_entry.activate += on_entry_activated;
        find_entry.changed += on_text_changed;
        find_entry.focus_in_event += on_receive_focus;

        // A width of 175 pixels is a sane minimum; the user can always expand this to be bigger
        list = new ListViewString(Gtk.TreeViewColumnSizing.FIXED, 175);
        list.row_activated += on_list_activated;
        list.received_focus += on_list_receive_focus;

        symbol_vbox = new Gtk.VBox(false, 6);
        symbol_vbox.pack_start(find_entry, false, false, 0);
        symbol_vbox.pack_start(list.scrolled_window, true, true, 0);
        symbol_vbox.show_all();

        weak Gedit.Panel panel = this.parent.window.get_side_panel();
        panel.add_item_with_stock_icon(symbol_vbox, "Symbols", Gtk.STOCK_FIND);
        
        panel.show += on_panel_open;
        panel.hide += on_panel_hide;
    }

    void on_text_changed() {
        on_update_symbols();
    }

    void on_panel_open(Gedit.Panel panel) {
        visible = true;
        on_receive_focus();
    }
    
    void on_panel_hide() {
        visible = false;
    }

    void on_list_receive_focus(Gtk.TreePath? path) {
        on_receive_focus();
        if (path != null)
            list.select_path(path);
    }

    bool on_receive_focus() {
        if (parent.active_document_is_valid_vala_file()) {
            parent.reparse_modified_documents(parent.active_filename());
            on_update_symbols();
        }
        
        return false;
    }

    public static void on_active_tab_changed(Gedit.Window window, Gedit.Tab tab, 
                                             SymbolBrowser browser) {
        browser.on_update_symbols();
    }

    void on_update_symbols() {
        string document_path = parent.active_filename();
        if (document_path == null || !Program.is_vala(document_path))
            return;
        
        Program program = Program.find_containing(document_path);

        if (program.is_parsing())
            program.system_parse_complete += update_symbols;
        else update_symbols();
    }

    SourceFile get_current_sourcefile() {
        string document_path = parent.active_filename();
        Program program = Program.find_containing(document_path);    
        SourceFile? sf = program.find_source(document_path);
        if (sf == null) {
            Gedit.Document doc = parent.window.get_active_document();
            program.update(document_path, buffer_contents(doc));
            sf = program.find_source(document_path);
        }

        assert(sf != null);
        return sf;
    }

    Expression parse_entry() {
        string text = find_entry.get_text().substring(0);
        if (!text.contains("."))
            return new Id(text);

        string[] ids = text.split(".");
        Expression e = new Id(ids[0]);
        for (int i = 1; i < ids.length; ++i) {
            e = new CompoundExpression(e, ids[i]);
        }
        return e;
    }

    void update_symbols() {
        if (!parent.active_document_is_valid_vala_file()) {
            list.clear();
            return;
        }
    
        Expression id = parse_entry();
        SourceFile sf = get_current_sourcefile();
        SymbolSet symbol_set = sf.resolve_all_locals(id, 0);

        weak HashSet<Symbol> symbols = symbol_set.get_symbols();
        string[] symbol_names;
        if (symbols != null) {
            // Insert symbol names into the list in a sorted order
            symbol_names = new string[symbols.size];

            int i = 0;
            foreach (Symbol symbol in symbols)
                symbol_names[i++] = symbol.name;
           
            qsort(symbol_names, symbols.size, sizeof(string), compare_string);
        } else symbol_names = new string[0];
        
        list.collate(symbol_names);
    }

    void jump_to_symbol(string symbol_name) {
        if (!parent.active_document_is_valid_vala_file())
            return;

        Expression id = new Id(symbol_name);
        SourceFile sf = get_current_sourcefile();
        Symbol? symbol = sf.resolve_local(id, 0);
        
        if (symbol == null)
            return;

        parent.jump(symbol.source.filename, 
                    new CharRange(symbol.start, symbol.start + (int) symbol.name.length));
    }

    void on_entry_activated() {
        if (list.size() <= 0)
            return;
        list.select_first_cell();
        on_list_activated();
    }

    void on_list_activated() {
        jump_to_symbol(list.get_selected_item());
    }
    
    public void on_document_saved() {
        if (visible)
            on_update_symbols();
    }

    public void set_parent_instance_focus() {
        Gedit.Panel panel = parent.window.get_side_panel();
        panel.show();
        
        panel.activate_item(symbol_vbox);
        parent.window.set_focus(find_entry);
    }

}

