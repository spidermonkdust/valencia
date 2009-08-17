/* Copyright 2009 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

using Gee;

extern void qsort(void *p, size_t num, size_t size, GLib.CompareFunc func);


////////////////////////////////////////////////////////////
//                 Helper data structures                 //
////////////////////////////////////////////////////////////

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

////////////////////////////////////////////////////////////
//                 GLib helper functions                  //
////////////////////////////////////////////////////////////

bool dir_has_parent(string dir, string parent) {
    GLib.File new_path = GLib.File.new_for_path(dir);
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

