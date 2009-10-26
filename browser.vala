/* Copyright 2009 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

using Gee;
using Valencia;

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

    void update_symbols() {
        if (!parent.active_document_is_valid_vala_file()) {
            list.clear();
            return;
        }
    
        string text = find_entry.get_text().substring(0);
        Expression id = new Id(text);
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
           
            qsort(symbol_names, symbols.size, sizeof(string), (GLib.CompareFunc) compare_string);
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

