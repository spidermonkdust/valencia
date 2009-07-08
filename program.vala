/* Copyright 2009 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

using Gee;

abstract class CompoundName : Object {
    public abstract string to_string();
}

class SimpleName : CompoundName {
    public string name;
    
    public SimpleName(string name) { this.name = name; }
    
    public override string to_string() { return name; }
}

class QualifiedName : CompoundName {
    public CompoundName basename;
    public string name;
    
    public QualifiedName(CompoundName basename, string name) {
        this.basename = basename;
        this.name = name;
    }
    
    public override string to_string() {
        return basename.to_string() + "." + name;
    }
}

abstract class Node : Object {
    public int start;
    public int end;
    
    Node(int start, int end) {
        this.start = start;
        this.end = end;
    }

    // Return all children which may possibly contain a scope.
    public virtual ArrayList<Node>? children() { return null; }
    
    protected static ArrayList<Node>? single_node(Node? n) {
        if (n == null)
            return null;
        ArrayList<Node> a = new ArrayList<Node>();
        a.add(n);
        return a;
    }
    
    public Chain? find(Chain? parent, int pos) {
        Chain c = parent;
        Scope s = this as Scope;
        if (s != null)
            c = new Chain(s, parent);    // link this scope in
            
        ArrayList<Node> nodes = children();
        if (nodes != null)
            foreach (Node n in nodes)
                if (n.start <= pos && pos <= n.end)
                    return n.find(c, pos);
        return c;
    }
    
    public static Symbol? lookup_in_array(ArrayList<Node> a, string name) {
        foreach (Node n in a) {
            Symbol s = n as Symbol;
            if (s != null && s.name == name)
                return s;
        }
        return null;
    }
    
    public abstract void print(int level);

    protected void do_print(int level, string s) {
        stdout.printf("%s%s\n", string.nfill(level * 2, ' '), s);
    }    
}

abstract class Symbol : Node {
    public SourceFile source;
    public string name;        // symbol name, or null for a constructor
    
    public Symbol(string? name, SourceFile source, int start, int end) {
        base(start, end);
        this.source = source;
        this.name = name;
    }
    
    protected void print_name(int level, string s) {
        do_print(level, s + " " + name);
    }
}

interface Scope : Object {
    public abstract Symbol? lookup(string name, int pos);
}

abstract class TypeSymbol : Symbol {
    public TypeSymbol(string? name, SourceFile source, int start, int end) {
        base(name, source, start, end);
    }
}

abstract class Statement : Node {
    public Statement(int start, int end) { base(start, end); }
    
    public virtual Symbol? defines_symbol(string name) { return null; }
}

abstract class Variable : Symbol {
    public CompoundName type;
    
    public Variable(CompoundName type, string name, SourceFile source, int start, int end) {
        base(name, source, start, end);
        this.type = type;
    }
    
    protected abstract string kind();
    
    public override void print(int level) {
        print_name(level, kind() + " " + type.to_string());
    }
}

class LocalVariable : Variable {
    public LocalVariable(CompoundName type, string name, SourceFile source, int start, int end) {
        base(type, name, source, start, end);
    }
    
    protected override string kind() { return "local"; }
}

class DeclarationStatement : Statement {
    public LocalVariable variable;
    
    public DeclarationStatement(LocalVariable variable, int start, int end) {
        base(start, end);
        this.variable = variable;
    }
    
    public override Symbol? defines_symbol(string name) {
        return variable.name == name ? variable : null;
    }
    
    public override void print(int level) {
        variable.print(level);
    }
}

class ForEach : Statement, Scope {
    public LocalVariable variable;
    public Statement statement;
    
    public ForEach(LocalVariable variable, Statement? statement, int start, int end) {
        base(start, end);
        this.variable = variable;
        this.statement = statement;
    }
    
    public override ArrayList<Node>? children() { return single_node(statement); }
    
    Symbol? lookup(string name, int pos) {
        return variable.name == name ? variable : null;
    }    
    
    protected override void print(int level) {
        do_print(level, "foreach");
        
        variable.print(level + 1);
        if (statement != null)
            statement.print(level + 1);
    }
}

class Chain : Object {
    Scope scope;
    Chain parent;
    
    public Chain(Scope scope, Chain? parent) {
        this.scope = scope;
        this.parent = parent;
    }
    
    public Symbol? lookup(string name, int pos) {
        Symbol s = scope.lookup(name, pos);
        if (s != null)
            return s;
        return parent == null ? null : parent.lookup(name, pos);
    }
    
    public TypeSymbol? lookup_type(string name) {
        TypeSymbol s = scope.lookup(name, 0) as TypeSymbol;
        if (s != null)
            return s;
        return parent == null ? null : parent.lookup_type(name);
    }
}

class Block : Statement, Scope {
    public ArrayList<Statement> statements = new ArrayList<Statement>();

    public override ArrayList<Node>? children() { return statements; }
    
    Symbol? lookup(string name, int pos) {
        foreach (Statement s in statements) {
            if (s.start > pos)
                return null;
            Symbol sym = s.defines_symbol(name);
            if (sym != null)
                return sym;
        }
        return null;
    }
    
    protected override void print(int level) {
        do_print(level, "block");
        
        foreach (Statement s in statements)
            s.print(level + 1);
    }
}

class Parameter : Variable {
    public Parameter(CompoundName type, string name, SourceFile source, int start, int end) {
        base(type, name, source, start, end);
    }
    
    protected override string kind() { return "parameter"; }
}

// a construct block
class Construct : Node {
    public Block body;
    
    public Construct(Block body, int start, int end) {
        base(start, end);
        this.body = body;
    }
    
    public override ArrayList<Node>? children() {
        return single_node(body);
    }

    public override void print(int level) {
        do_print(level, "construct");
        if (body != null)
            body.print(level + 1);
    }
}

class Method : Symbol, Scope {
    public ArrayList<Parameter> parameters = new ArrayList<Parameter>();
    public Block body;
    
    public Method(string? name, SourceFile source) { base(name, source, 0, 0); }
    
    public override ArrayList<Node>? children() { return single_node(body);    }
    
    Symbol? lookup(string name, int pos) {
        return Node.lookup_in_array(parameters, name);
    }
    
    protected virtual void print_type(int level) {
        print_name(level, "method");
    }
    
    public override void print(int level) {
        print_type(level);
        
        foreach (Parameter p in parameters)
            p.print(level + 1);
        if (body != null)
            body.print(level + 1);
    }
}

class Constructor : Method {
    public Constructor(SourceFile source) { base(null, source); }
    
    public override void print_type(int level) {
        do_print(level, "constructor");
    }
}

class Field : Variable {
    public Field(CompoundName type, string name, SourceFile source, int start, int end) {
        base(type, name, source, start, end);
    }
    
    protected override string kind() { return "field"; }
}

class Property : Variable {
    // A Block containing property getters and/or setters.
    public Block body;

    public Property(CompoundName type, string name, SourceFile source, int start, int end) {
        base(type, name, source, start, end);
    }
    
    public override ArrayList<Node>? children() {
        return single_node(body);
    }

    protected override string kind() { return "property"; }

    public override void print(int level) {
        base.print(level);
        body.print(level + 1);
    }
}

// a class, struct, interface or enum
class Class : TypeSymbol, Scope {
    public ArrayList<CompoundName> super = new ArrayList<CompoundName>();
    public ArrayList<Node> members = new ArrayList<Node>();
    
    public Class(string name, SourceFile source) { base(name, source, 0, 0); }
    
    public override ArrayList<Node>? children() { return members; }
    
    Symbol? lookup1(string name, HashSet<Class> seen) {
        Symbol sym = Node.lookup_in_array(members, name);
        if (sym != null)
            return sym;

        // look in superclasses
        
        seen.add(this);
        
        foreach (CompoundName s in super) {
            // We look up the parent class in the scope at (start - 1); that excludes
            // this class itself (but will include the containing sourcefile,
            // even if start == 0.)
            Class c = source.resolve_type(s, start - 1) as Class;
            
            if (c != null && !seen.contains(c)) {
                sym = c.lookup1(name, seen);
                if (sym != null)
                    return sym;
            }
        }
        return null;
        
    }    
    
    Symbol? lookup(string name, int pos) {
        return lookup1(name, new HashSet<Class>());
    }
    
    public override void print(int level) {
        StringBuilder sb = new StringBuilder();
        sb.append("class " + name);
        for (int i = 0 ; i < super.size ; ++i) {
            sb.append(i == 0 ? " : " : ", ");
            sb.append(super.get(i).to_string());
        }
        do_print(level, sb.str);
        
        foreach (Node n in members)
            n.print(level + 1);
    }
}

// A Namespace is a TypeSymbol since namespaces can be used in type names.
class Namespace : TypeSymbol, Scope {
    public string full_name;
    
    public Namespace(string? name, string? full_name, SourceFile source) {
        base(name, source, 0, 0);
        this.full_name = full_name;
    }
    
    public ArrayList<Symbol> symbols = new ArrayList<Symbol>();
    
    public override ArrayList<Node>? children() { return symbols; }

    public Symbol? lookup(string name, int pos) {
        return source.program.lookup_in_namespace(full_name, name); 
    }
    
    public Symbol? lookup1(string name) {
        return Node.lookup_in_array(symbols, name);
    }

    public override void print(int level) {
        print_name(level, "namespace");
        foreach (Symbol s in symbols)
            s.print(level + 1);
    }
}

class SourceFile : Node, Scope {
    public weak Program program;
    public string filename;
    
    public ArrayList<string> using_namespaces = new ArrayList<string>();
    public ArrayList<Namespace> namespaces = new ArrayList<Namespace>();
    public Namespace top;
    
    public SourceFile(Program? program, string filename) {
        this.program = program;
        this.filename = filename;
        alloc_top();
    }
    
    void alloc_top() {
        top = new Namespace(null, null, this);
        namespaces.add(top);
    }
    
    public void clear() {
        using_namespaces.clear();
        namespaces.clear();
        alloc_top();
    }

    public override ArrayList<Node>? children() { return single_node(top);    }
    
    Symbol? lookup(string name, int pos) {
        foreach (string ns in using_namespaces) {
            Symbol s = program.lookup_in_namespace(ns, name);
            if (s != null)
                return s;
        }
        return null;
    }

    public Symbol? lookup_in_namespace(string? namespace_name, string name) {
        foreach (Namespace n in namespaces)
            if (n.full_name == namespace_name) {
                Symbol s = n.lookup1(name);
                if (s != null)
                    return s;
            }
        return null;
    }

    public Symbol? resolve1(CompoundName name, Chain chain, int pos, bool find_type) {
        SimpleName s = name as SimpleName;
        if (s != null)
            return find_type ? chain.lookup_type(s.name) : chain.lookup(s.name, pos);
        
        QualifiedName q = (QualifiedName) name;
        Symbol left = resolve1(q.basename, chain, pos, find_type);
        if (!find_type) {
            Variable v = left as Variable;
            if (v != null)
                left = v.source.resolve_type(v.type, v.start);
        }
        Scope scope = left as Scope;
        return scope == null ? null : scope.lookup(q.name, 0);
    }
    
    public Symbol? resolve(CompoundName name, int pos) {
        return resolve1(name, find(null, pos), pos, false);
    }    
    
    public Symbol? resolve_type(CompoundName type, int pos) {
        return resolve1(type, find(null, pos), 0, true);
    }
    
    public override void print(int level) {
        top.print(level);
    }    
}

class Makefile : Object {
    public string path;
    public string relative_binary_run_path;
    
    bool regex_parse(GLib.DataInputStream datastream) {
        Regex program_regex, rule_regex, root_regex;
        try {            
            root_regex = new Regex("""^ *BUILD_ROOT *= *1$""");
            program_regex = new Regex("""^ *PROGRAM *= *(.+) *$""");
            rule_regex = new Regex("""^ *([^: ]+) *:""");
        } catch (RegexError e) {
            GLib.warning("A RegexError occured when creating a new regular expression.\n");
            return false;        // TODO: report error
        }

        bool rule_matched = false;
        bool program_matched = false;
        bool root_matched = false;
        MatchInfo info;

        // this line is necessary because of a vala compiler bug that thinks info is uninitialized
        // within the block: if (!program_matched && program_regex.match(line, 0, out info)) {
        program_regex.match(" ", 0, out info);
            
        while (true) {
            size_t length;
            string line;
           
            try {
                line = datastream.read_line(out length, null);
            } catch (GLib.Error err) {
                GLib.warning("An unexpected error occurred while parsing the Makefile.\n");
                return false;
            }
            
            // The end of the document was reached, ending...
            if (line == null)
                break;
            
            if (!program_matched && program_regex.match(line, 0, out info)) {
                // The 'PROGRAM = xyz' regex can be matched anywhere in the makefile, where the rule
                // regex can only be matched the first time.
                relative_binary_run_path = info.fetch(1);
                program_matched = true;
            } else if (!rule_matched && !program_matched && rule_regex.match(line, 0, out info)) {
                rule_matched = true;
                relative_binary_run_path = info.fetch(1);
            } else if (!root_matched && root_regex.match(line, 0, out info)) {
                root_matched = true;
            }

            if (program_matched && root_matched)
                break;
        }
        
        return root_matched;
    }
    
    // Return: true if current directory will be root, false if not
    public bool parse(GLib.File makefile) {
        GLib.FileInputStream stream;
        try {
            stream = makefile.read(null);
         } catch (GLib.Error err) {
            GLib.warning("Unable to open %s for parsing.\n", path);
            return false;
         }
        GLib.DataInputStream datastream = new GLib.DataInputStream(stream);
        
        return regex_parse(datastream);
    }

    public void reparse() {
        if (path == null)
            return;
            
        GLib.File makefile = GLib.File.new_for_path(path);
        parse(makefile);
    }
    
    public void reset_paths() {
        path = null;
        relative_binary_run_path = null;
    }
    
}

class Program : Object {
    public ErrorList error_list;

    string top_directory;
    ArrayList<SourceFile> sources = new ArrayList<SourceFile>();
    
    static ArrayList<Program> programs;
    
    Makefile makefile;

    bool recursive_project;

    Program(string directory) {
        error_list = null;
        top_directory = null;
        makefile = new Makefile();
        
        // Search for the program's makefile; if the top_directory still hasn't been modified
        // (meaning no makefile at all has been found), then just set it to the default directory
        File makefile_dir = File.new_for_path(directory);
        if (get_makefile_directory(makefile_dir)) {
            // Recursively add source files to the program
            scan_directory_for_sources(top_directory, true);
            recursive_project = true;
        } else {
            // If no root directory was found, make sure there is a local top directory, and 
            // scan only that directory for sources
            top_directory = directory;
            scan_directory_for_sources(top_directory, false);
            recursive_project = false;
        }
        
        programs.add(this);
    }

    // Returns true if a BUILD_ROOT or configure.ac was found: files should be found recursively
    // False if only the local directory will be used
    bool get_makefile_directory(GLib.File makefile_dir) {
        if (configure_exists_in_directory(makefile_dir))
            return true;
    
        GLib.File makefile_file = makefile_dir.get_child("Makefile");
        if (!makefile_file.query_exists(null)) {
            makefile_file = makefile_dir.get_child("makefile");
            
            if (!makefile_file.query_exists(null)) {
                makefile_file = makefile_dir.get_child("GNUmakefile");
                
                if (!makefile_file.query_exists(null)) {
                    return goto_parent_directory(makefile_dir);
                }
            }
        }

        // Set the top_directory to be the first BUILD_ROOT we come across
        if (makefile.parse(makefile_file)) {
            set_paths(makefile_file);
            return true;
        }
        
        return goto_parent_directory(makefile_dir);
    }
    
    bool goto_parent_directory(GLib.File base_directory) {
        GLib.File parent_dir = base_directory.get_parent();
        return parent_dir != null && get_makefile_directory(parent_dir);
    }
    
    bool configure_exists_in_directory(GLib.File configure_dir) {
        GLib.File configure = configure_dir.get_child("configure.ac");
        
        if (!configure.query_exists(null)) {
            configure = configure_dir.get_child("configure.in");
    
            if (!configure.query_exists(null))
                return false;
        }

        // If there's a configure file, don't bother parsing for a makefile        
        top_directory = configure_dir.get_path();
        makefile.reset_paths();

        return true;
    }

    void set_paths(GLib.File makefile_file) {
        makefile.path = makefile_file.get_path();
        top_directory = Path.get_dirname(makefile.path);
    }
    
    // Adds vala files in the directory to the program, as well as parses them
    void scan_directory_for_sources(string directory, bool recursive) {
        Dir dir;
        try {
            dir = Dir.open(directory);
        } catch (GLib.FileError e) {
            GLib.warning("Error opening directory: %s\n", directory);
            return;
        }
        
        Parser parser = new Parser();
        while (true) {
            string file = dir.read_name();
            if (file == null)
                break;
             string path = Path.build_filename(directory, file);

            if (is_vala(file)) {
                SourceFile source = new SourceFile(this, path);
                string contents;
                
                try {
                    FileUtils.get_contents(path, out contents);
                } catch (GLib.FileError e) {
                    // needs a message box? stderr.printf message?
                    return;
                }
                parser.parse(source, contents);
                sources.add(source);
            } else if (recursive && GLib.FileUtils.test(path, GLib.FileTest.IS_DIR)) {
                scan_directory_for_sources(path, true);
            }
        }
    }
    
    public static bool is_vala(string filename) {
        return filename.has_suffix(".vala") ||
               filename.has_suffix(".vapi") ||
               filename.has_suffix(".cs");    // C#
    }
    
    public Symbol? lookup_in_namespace1(string? namespace_name, string name, bool vapi) {
        foreach (SourceFile source in sources)
            if (source.filename.has_suffix(".vapi") == vapi) {
                Symbol s = source.lookup_in_namespace(namespace_name, name);
                if (s != null)
                    return s;
            }
        return null;
    }

    public Symbol? lookup_in_namespace(string? namespace_name, string name) {
        // First look in non-vapi files; we'd like definitions here to have precedence.
        Symbol s = lookup_in_namespace1(namespace_name, name, false);
        if (s == null)
            s = lookup_in_namespace1(namespace_name, name, true);   // look in .vapi files
        return s;
    }    

    public SourceFile? find_source(string path) {
        foreach (SourceFile source in sources)
            if (source.filename == path)
                return source;
        return null;
    }
    
    // Update the text of a (possibly new) source file in this program.
    void update1(string path, string contents) {
        SourceFile source = find_source(path);
        if (source == null) {
            source = new SourceFile(this, path);
            sources.add(source);
        } else source.clear();
        new Parser().parse(source, contents);
    }
    
    public void update(string path, string contents) {
        if (!is_vala(path))
            return;
            
        if (recursive_project && dir_has_parent(path, top_directory)) {
            update1(path, contents);
            return;
        }
        
        string path_dir = Path.get_dirname(path);    
        if (top_directory == path_dir)
            update1(path, contents);
    }
    
    static Program? find_program(string dir) {
        if (programs == null)
            programs = new ArrayList<Program>();
            
        foreach (Program p in programs)
            if (p.recursive_project && dir_has_parent(dir, p.get_top_directory()))
                return p;
            else if (p.top_directory == dir)
                return p;
        return null;
    }
    
    public static Program find_containing(string path) {
        string dir = Path.get_dirname(path);
        Program p = find_program(dir);
        return p != null ? p : new Program(dir);
    }
    
    public static Program? null_find_containing(string? path) {
        if (path == null)
            return null;
        string dir = Path.get_dirname(path);
        return find_program(dir);    
    }

    // Update the text of a (possibly new) source file in any existing program.
    // If (contents) is null, we read the file's contents from disk.
    public static void update_any(string path, string? contents) {
        if (!is_vala(path))
            return;
          
          // If no program exists for this file, don't even bother looking
        string dir = Path.get_dirname(path);
          if (find_program(dir) == null)
              return;
          
        string contents1;        // owning variable
        if (contents == null) {
            try {
                FileUtils.get_contents(path, out contents1);
            } catch (FileError e) { 
                GLib.warning("Unable to open %s for updating\n", path);
                return; 
            }
            contents = contents1;
        }

        // Make sure to update the file for each sourcefile
        foreach (Program program in programs) {
            SourceFile sf = program.find_source(path);
                if (sf != null)
                    program.update1(path, contents);
        }
    }
    
    public static void rescan_build_root(string sourcefile_path) {
        Program? program = find_program(Path.get_dirname(sourcefile_path));
        
        if (program == null)
            return;

        File current_dir = File.new_for_path(Path.get_dirname(sourcefile_path));        
        string old_top_directory = program.top_directory;
        string local_directory = current_dir.get_path();

        // get_makefile_directory will set top_directory to the path of the makefile it found - 
        // if the path is the same as the old top_directory, then no changes have been made
        bool found_root = program.get_makefile_directory(current_dir);

        // If a root was found and the new and old directories are the same, the old root was found:
        // nothing changes.
        if (found_root && old_top_directory == program.top_directory)
            return;
        if (!found_root && old_top_directory == local_directory)
            return;

        // If a new root was found, get_makefile_directory() will have changed program.top_directory
        // already; if not, then we need to set it to the local directory manually
        if (!found_root)
            program.top_directory = local_directory;

        // The build root has changed, so: 
        // 1) delete the old root
        assert(programs.size > 0);
        programs.remove(program);

         // 2) delete a program rooted at the new directory if one exists
        foreach (Program p in programs)
            if (p.top_directory == program.top_directory)
                programs.remove(p);
            
         // 3) create a new program at new build root
        new Program(program.top_directory);
    }    
    
    public string get_top_directory() {
        return top_directory;
    }

    public string? get_binary_run_path() {
        if (makefile.relative_binary_run_path == null)
            return null;
        return Path.build_filename(top_directory, makefile.relative_binary_run_path);
    }
    
    public bool get_binary_is_executable() {
        string? binary_path = get_binary_run_path();
        return binary_path != null && !binary_path.has_suffix(".so");
    }
    
    public void reparse_makefile() {
        makefile.reparse();
    }
    
}

