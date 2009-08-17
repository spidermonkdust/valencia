/* Copyright 2009 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

////////////////////////////////////////////////////////////
//                    Helper functions                    //
////////////////////////////////////////////////////////////

public void show_error_dialog(string message) {
    Gtk.MessageDialog err_dialog = new Gtk.MessageDialog(null, Gtk.DialogFlags.MODAL, 
                                                Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, 
                                                message, null);
    err_dialog.set_title("Error");
    err_dialog.run(); 
    err_dialog.destroy(); 
}

string get_full_line_from_text_iter(Gtk.TextIter iter) {
    // Move the iterator back to the beginning of its line
    iter.backward_chars(iter.get_line_offset());
    // Get an iterator at the end of the line
    Gtk.TextIter end = iter;
    end.forward_line();
    
    return iter.get_text(end);
}

void get_coords_at_buffer_offset(Gedit.Window window, int offset, bool above, bool beside,
                                 out int x, out int y) {
    Gedit.Document buffer = window.get_active_document();
    Gtk.TextIter method_iter;
    buffer.get_iter_at_offset(out method_iter, offset);
    
    Gedit.View active_view = window.get_active_view();
    Gdk.Rectangle rect;
    active_view.get_iter_location(method_iter, out rect);
    int win_x, win_y;
    active_view.buffer_to_window_coords(Gtk.TextWindowType.WIDGET, rect.x, rect.y, 
                                        out win_x, out win_y);
    int widget_x = active_view.allocation.x;
    int widget_y = active_view.allocation.y; 
    int orig_x, orig_y;
    window.window.get_origin(out orig_x, out orig_y);

    x = win_x + widget_x + orig_x;
    y = win_y + widget_y + orig_y;
    x += beside ? rect.height : 0; 
    y -= above ? rect.height : 0;
}

////////////////////////////////////////////////////////////
//                        Classes                         //
////////////////////////////////////////////////////////////

class Tooltip {
  weak Gedit.Window parent;
  Gtk.Window window;
  Gtk.Label tip_text;
  Gtk.TextMark method_mark;
  string method_name;
  bool visible;

  public Tooltip(Gedit.Window parent_win) {
      parent = parent_win;
      visible = false;
      tip_text = new Gtk.Label("");
      window = new Gtk.Window(Gtk.WindowType.POPUP);
      
      window.add(tip_text);
      window.set_default_size(1, 1);
      window.set_transient_for(parent);
      window.set_destroy_with_parent(true);
      
      Gdk.Color background;
      Gdk.Color.parse("#FFFF99", out background);
      window.modify_bg(Gtk.StateType.NORMAL, background);
  }

  public void show(string qualified_method_name, string prototype, int method_pos) {
      method_name = qualified_method_name;
      visible = true;

      Gedit.Document document = parent.get_active_document();
      Gtk.TextIter method_iter;
      document.get_iter_at_offset(out method_iter, method_pos);
      method_mark = document.create_mark(null, method_iter, true);
      tip_text.set_text(prototype);

      int x, y;
      get_coords_at_buffer_offset(parent, method_pos, true, false, out x, out y);
      window.move(x, y);
      window.resize(1, 1);
      window.show_all();
  }

  public void hide() {
      if (!visible)
          return;

      assert(!method_mark.get_deleted());
      Gtk.TextBuffer doc = method_mark.get_buffer();
      doc.delete_mark(method_mark);
      
      visible = false;
      window.hide_all();
  }
  
  public bool is_visible() {
      return visible;
  }
  
  public string get_method_line() {
      assert(!method_mark.get_deleted());
      Gtk.TextBuffer doc = method_mark.get_buffer();
      Gtk.TextIter iter;
      doc.get_iter_at_mark(out iter, method_mark);
      return get_full_line_from_text_iter(iter);
  }

  public Gtk.TextIter get_iter_at_method() {
      assert(!method_mark.get_deleted());
      Gtk.TextBuffer doc = method_mark.get_buffer();
      Gtk.TextIter iter;
      doc.get_iter_at_mark(out iter, method_mark);
      return iter;
  }
  
  public string get_method_name() {
      return method_name;
  }
}

class ProgressBarDialog : Gtk.Window {
  Gtk.ProgressBar bar;

  public ProgressBarDialog(Gtk.Window parent_win, string text) {
      bar = new Gtk.ProgressBar();
      Gtk.VBox vbox = new Gtk.VBox(true, 0);
      Gtk.HBox hbox = new Gtk.HBox(true, 0);

      bar.set_text(text);
      bar.set_size_request(226, 25);
      set_size_request(250, 49);

      vbox.pack_start(bar, true, false, 0);
      hbox.pack_start(vbox, true, false, 0);   
      add(hbox);
      set_title(text);

      set_resizable(false);
      set_transient_for(parent_win);
      set_modal(true);
      show_all();
  }
  
  public void set_percentage(double percent) {
      bar.set_fraction(percent);
  }
  
  public void close() {
      hide();
  }
}
