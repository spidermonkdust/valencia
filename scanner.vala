enum Token {
	NONE,
	EOF,
	CHAR,	// an unrecognized punctuation character
	CHAR_LITERAL,	// a literal such as 'x'
	STRING_LITERAL,
	ID,
	
	// punctuation characters
	ASTERISK, LEFT_BRACE, RIGHT_BRACE, LEFT_BRACKET, RIGHT_BRACKET, COLON, COMMA, EQUALS,
	HASH, LEFT_PAREN, RIGHT_PAREN, PERIOD, QUESTION_MARK, SEMICOLON, LESS_THAN, GREATER_THAN,
	
	// keywords
	ABSTRACT, CLASS, CONST, CONSTRUCT, DELEGATE, ENUM, FOREACH, INTERFACE, NAMESPACE, NEW, OUT,
	OVERRIDE, OWNED, PRIVATE, PROTECTED, PUBLIC, REF, RETURN, SIGNAL, STATIC, STRUCT, UNOWNED,
    USING, VIRTUAL, WEAK
}

struct Keyword {
	public string name;
	public Token token;
}

const Keyword[] keywords = {
	{ "abstract", Token.ABSTRACT },
	{ "class", Token.CLASS },
	{ "const", Token.CONST },
	{ "construct", Token.CONSTRUCT },
	{ "delegate", Token.DELEGATE },
	{ "enum", Token.ENUM },
	{ "foreach", Token.FOREACH },
	{ "interface", Token.INTERFACE },
	{ "namespace", Token.NAMESPACE },
	{ "new", Token.NEW },
	{ "out", Token.OUT },
	{ "override", Token.OVERRIDE },
    { "owned", Token.OWNED },
	{ "private", Token.PRIVATE },
	{ "protected", Token.PROTECTED },
	{ "public", Token.PUBLIC },
	{ "ref", Token.REF },
	{ "return", Token.RETURN },
	{ "signal", Token.SIGNAL },
	{ "static", Token.STATIC },
	{ "struct", Token.STRUCT },
    { "unowned", Token.UNOWNED },
	{ "using", Token.USING },
	{ "virtual", Token.VIRTUAL },
	{ "weak", Token.WEAK }
};

class Scanner : Object {
	// The lookahead token.  If not NONE, it extends from characters (token_start_char) to (input),
	// and from positions (token_start) to (input_pos).
	Token token = Token.NONE;
	
	weak string token_start_char;
	weak string input;
	
	int token_start;
	int input_pos;
	
	// The last token retrieved with next_token() extends from characters (start_char) to
	// (end_char), and from positions (start) to (end).
	weak string start_char;
	weak string end_char;
	public int start;	// starting character position
	public int end;	    // ending character position
	
	public Scanner(string input) {
		this.input = input;
	}

	void advance() {
		input = input.next_char();
		++input_pos;
	}
	
	unichar peek_char() { return input.get_char(); }
	
	unichar next_char() {
		unichar c = peek_char();
		advance();
		return c;
	}
	
	bool accept(unichar c) {
		if (peek_char() == c) {
			advance();
			return true;
		}
		return false;
	}

	// Return true if the current token equals s.	
	bool match(string s) {
		char *p = token_start_char;
		char *q = s;
		while (*p != 0 && *q != 0 && *p == *q) {
			p = p + 1;
			q = q + 1;
		}
		return p == input && *q == 0;
	}
	
	// Read characters until we reach a triple quote (""") string terminator.
	void read_triple_string() {
		while (input != "")
			if (next_char() == '"' && accept('"') && accept('"'))
				return;
	}
	
	Token read_token() {
		while (input != "") {
			token_start_char = input;
			token_start = input_pos;
			unichar c = next_char();
			if (c.isspace())
				continue;
			if (c.isalpha() || c == '_') {		// identifier start
				while (true) {
					c = peek_char();
					if (!c.isalnum() && c != '_')
						break;
					advance();
				}
				foreach (Keyword k in keywords)
					if (match(k.name))
						return k.token;
				return Token.ID;
			}
			switch (c) {
				case '/':
					unichar d = peek_char();
					if (d == '/') {    // single-line comment
						while (input != "" && next_char() != '\n')
							;
						continue;
					}
					if (d == '*') {	   // multi-line comment
						advance();	// move past '*'
						while (input != "") { 
							if (next_char() == '*' && peek_char() == '/') {
								advance();	// move past '/'
								break;
							}
						}
						continue;
					}
					return Token.CHAR;
				case '"':
					if (accept('"')) {	    // ""
						if (accept('"'))	// """
							read_triple_string();
					} else {
						while (input != "") {
							unichar d = next_char();
							if (d == '"' || d == '\n')
								break;
							else if (d == '\'')	// escape sequence
								advance();
						}
					}
					return Token.STRING_LITERAL;
				case '\'':
					accept('\\');	// optional backslash beginning escape sequence
					advance();
					accept('\'');	// closing single quote
					return Token.CHAR_LITERAL;
				case '*': return Token.ASTERISK;
				case '{': return Token.LEFT_BRACE;
				case '}': return Token.RIGHT_BRACE;
				case '[': return Token.LEFT_BRACKET;
				case ']': return Token.RIGHT_BRACKET;
				case ':': return Token.COLON;
				case ',': return Token.COMMA;
				case '=': return Token.EQUALS;
				case '#': return Token.HASH;
				case '(': return Token.LEFT_PAREN;
				case ')': return Token.RIGHT_PAREN;
				case '.': return Token.PERIOD;
				case '?': return Token.QUESTION_MARK;
				case ';': return Token.SEMICOLON;
				case '<': return Token.LESS_THAN;
				case '>': return Token.GREATER_THAN;
				default:  return Token.CHAR;
			}
		}
		return Token.EOF;
	}
	
	public Token peek_token() {
		if (token == Token.NONE)
			token = read_token();
		return token;
	}
	
	public Token next_token() {
		Token t = peek_token();
		token = Token.NONE;
		start_char = token_start_char;
		end_char = input;
		start = token_start;
		end = input_pos;
		return t;
	}
	
	public bool eof() { return peek_token() == Token.EOF; }

	// Return the source text of the last token retrieved.
	public string val() {
		size_t bytes = (char *) end_char - (char *) start_char;
		return start_char.ndup(bytes);
	} 
}

