/* Copyright 2009 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

bool dir_has_parent(string dir, string parent) {
    GLib.File new_path = GLib.File.new_for_path(dir);
    while (parent != new_path.get_path()) {
        new_path = new_path.get_parent();
        
        if (new_path == null)
            return false;
    }
    
    return true;
}

public void show_error_dialog(string message) {
    Gtk.MessageDialog err_dialog = new Gtk.MessageDialog(null, Gtk.DialogFlags.MODAL, 
                                                Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, 
                                                message, null);
    err_dialog.set_title("Error");
    err_dialog.run(); 
    err_dialog.destroy(); 
}

