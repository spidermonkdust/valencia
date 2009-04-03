using Gee;

abstract class Node : Object {
	public int start;
	public int end;
	
	Node(int start, int end) {
		this.start = start;
		this.end = end;
	}
	
	// Return all children which may possibly contain a scope.
	public virtual ArrayList<Node>? children() { return null; }
	
	protected static ArrayList<Node>? single_node(Node n) {
		if (n == null)
			return null;
		ArrayList<Node> a = new ArrayList<Node>();
		a.add(n);
		return a;
	}
	
	protected Chain? find(Chain? parent, int pos) {
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
	public string name;		// symbol name, or null for a constructor
	
	public Symbol(string? name, int start, int end) {
		base(start, end);
		this.name = name;
	}
	
	protected void print_name(int level, string s) {
		do_print(level, s + " " + name);
	}
}

abstract class TypeSymbol : Symbol {
	public TypeSymbol(string name, int start, int end) { base(name, start, end); }
}

abstract class Statement : Node {
	public Statement(int start, int end) { base(start, end); }
	
	public virtual Symbol? defines_symbol(string name) { return null; }
}

abstract class DataType : Node {
	public abstract string to_string();
	public override void print(int level) { }
}

abstract class TypeName : DataType { }

class SimpleName : TypeName {
	public string name;
	
	public SimpleName(string name) { this.name = name; }
	
	public override string to_string() { return name; }
}

class QualifiedName : TypeName {
	public TypeName basename;
	public string sub;
	
	public QualifiedName(TypeName basename, string sub) {
		this.basename = basename;
		this.sub = sub;
	}
	
	public override string to_string() {
		return basename.to_string() + "." + sub;
	}
}

abstract class Variable : Symbol {
	DataType type;
	
	public Variable(DataType type, string name, int start, int end) {
		base(name, start, end);
		this.type = type;
	}
	
	protected abstract string kind();
	
	public override void print(int level) {
		print_name(level, kind() + " " + type.to_string());
	}
}

class LocalVariable : Variable {
	public LocalVariable(DataType type, string name, int start, int end) {
		base(type, name, start, end);
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

interface Scope : Object {
	public abstract Symbol? lookup(string name, int pos);
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
	public Parameter(DataType type, string name, int start, int end) {
		base(type, name, start, end);
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
	
	public Method(string? name) { base(name, 0, 0); }
	
	public override ArrayList<Node>? children() {
		return single_node(body);
	}
	
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
	public Constructor() { base(null); }
	
	public override void print_type(int level) {
		do_print(level, "constructor");
	}
}

class Field : Variable {
	public Field(DataType type, string name, int start, int end) {
		base(type, name, start, end);
	}
	
	protected override string kind() { return "field"; }
}

// a class, struct or interface
class Class : TypeSymbol, Scope {
	public ArrayList<Node> members = new ArrayList<Node>();
	
	public Class(string name) { base(name, 0, 0); }
	
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

class Enum : TypeSymbol {
	public Enum(string name, int start, int end) { base(name, start, end); }
	
	public override void print(int level) { print_name(level, "enum"); }	
}

class SourceFile : Node, Scope {
	public ArrayList<string> using_namespaces = new ArrayList<string>();
	public ArrayList<Symbol> symbols = new ArrayList<Symbol>();
	
	public override ArrayList<Node>? children() { return symbols; }

	Symbol? lookup(string name, int pos) {
		return Node.lookup_in_array(symbols, name);
	}

	public Symbol? resolve(string name, int pos) {
		Chain c = find(null, pos);
		return c.lookup(name, pos);
	}
	
	public override void print(int level) {
		foreach (Symbol s in symbols)
			s.print(level);
	}
}

