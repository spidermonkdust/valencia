bool dir_has_parent(string dir, string parent) {
    GLib.File new_path = GLib.File.new_for_path(dir);
    while (parent != new_path.get_path()) {
        new_path = new_path.get_parent();
        
        if (new_path == null)
            return false;
    }
    
    return true;
}


