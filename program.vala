using Gee;

abstract class CompoundName {
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
			c = new Chain(s, parent);	// link this scope in
			
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
	public string name;		// symbol name, or null for a constructor
	
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

class Chain {
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
	
	public override ArrayList<Node>? children() { return single_node(body);	}
	
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

// a class, struct, interface or enum
class Class : TypeSymbol, Scope {
	public ArrayList<Node> members = new ArrayList<Node>();
	
	public Class(string name, SourceFile source) { base(name, source, 0, 0); }
	
	public override ArrayList<Node>? children() { return members; }
	
	Symbol? lookup(string name, int pos) {
		return Node.lookup_in_array(members, name);
	}
	
	public override void print(int level) {
		print_name(level, "class");
		
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

	public override ArrayList<Node>? children() { return single_node(top);	}
	
	Symbol? lookup(string name, int pos) {
		foreach (string ns in using_namespaces) {
			Symbol s = program.lookup_in_namespace(ns, name);
			if (s != null)
				return s;
		}
		return null;
	}

	static Chain? symbol_chain(Symbol symbol) {
		return symbol.source.find(null, symbol.start);
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
				left = resolve1(v.type, symbol_chain(v), 0, true);
		}
		Scope scope = left as Scope;
		return scope == null ? null : scope.lookup(q.name, 0);
	}
	
	public Symbol? resolve(CompoundName name, int pos) {
		return resolve1(name, find(null, pos), pos, false);
	}	
	
	public override void print(int level) {
		top.print(level);
	}	
}

class Program : Object {
	string directory;
	ArrayList<SourceFile> sources = new ArrayList<SourceFile>();
	
	static ArrayList<Program> programs;
	
	Program(string directory) {
		this.directory = directory;
		Dir dir = Dir.open(directory);
		Parser parser = new Parser();
		while (true) {
			string file = dir.read_name();
			if (file == null)
				break;
			if (is_vala(file)) {
				string path = Path.build_filename(directory, file);
				SourceFile source = new SourceFile(this, path);
				string contents;
				FileUtils.get_contents(path, out contents);
				parser.parse(source, contents);
				sources.add(source);
			}
		}
		
		programs.add(this);
	}
	
	static bool is_vala(string filename) {
		return filename.has_suffix(".vala") || filename.has_suffix(".vapi");
	}
	
	public Symbol? lookup_in_namespace(string? namespace_name, string name) {
		foreach (SourceFile source in sources)
			foreach (Namespace n in source.namespaces)
				if (n.full_name == namespace_name) {
					Symbol s = n.lookup1(name);
					if (s != null)
						return s;
				}
		return null;
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
		if (is_vala(path) && Path.get_dirname(path) == directory)
			update1(path, contents);
	}
	
	static Program? find_program(string dir) {
		if (programs == null)
			programs = new ArrayList<Program>();
			
		foreach (Program p in programs)
			if (p.directory == dir)
				return p;
		return null;
	}
	
	public static Program find_containing(string path) {
		string dir = Path.get_dirname(path);
		Program p = find_program(dir);
		return p != null ? p : new Program(dir);
	}

	// Update the text of a (possibly new) source file in any existing program.
	// If (contents) is null, we read the file's contents from disk.
	public static void update_any(string path, string? contents) {
		if (path == null || !is_vala(path))
			return;
		string dir = Path.get_dirname(path);
		Program p = find_program(dir);
		if (p != null) {
			string contents1;		// owning variable
			if (contents == null) {
				try {
					FileUtils.get_contents(path, out contents1);
				} catch (FileError e) { return; }
				contents = contents1;
			}
			p.update1(path, contents);
		}
	}
}

