enum Token {
	NONE,
	EOF,
	CHAR,	// an unrecognized punctuation character
	ID,
	CHAR_LITERAL,	// a literal such as 'x'
	
	// punctuation characters
	ASTERISK, LEFT_BRACE, RIGHT_BRACE, LEFT_BRACKET, RIGHT_BRACKET, COMMA, EQUALS,
	LEFT_PAREN, RIGHT_PAREN, PERIOD, QUESTION_MARK, SEMICOLON, LESS_THAN, GREATER_THAN,
	
	// keywords
	ABSTRACT, CLASS, CONST, CONSTRUCT, ENUM, INTERFACE, OUT, OVERRIDE, PRIVATE, PROTECTED, PUBLIC,
	REF, RETURN, STATIC, STRUCT, USING, VIRTUAL, WEAK
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
	{ "enum", Token.ENUM },
	{ "interface", Token.INTERFACE },
	{ "out", Token.OUT },
	{ "override", Token.OVERRIDE },
	{ "private", Token.PRIVATE },
	{ "protected", Token.PROTECTED },
	{ "public", Token.PUBLIC },
	{ "ref", Token.REF },
	{ "return", Token.RETURN },
	{ "static", Token.STATIC },
	{ "struct", Token.STRUCT },
	{ "using", Token.USING },
	{ "virtual", Token.VIRTUAL },
	{ "weak", Token.WEAK }
};

class Scanner {
	weak string input;
	int input_pos;
	
	// The lookahead token.  If not NONE, it extends from characters (token_start) to (input),
	// and from positions (token_start_pos) to (input_pos).
	Token token = Token.NONE;
	weak string token_start;
	int token_start_pos;
	
	// The following variables apply to the last token retrieved with next_token().
	public int start;	// starting character position
	public int end;	    // ending character position
	
	public Scanner(string input) {
		this.input = input;
	}

	void advance() {
		input = input.next_char();
		++input_pos;
	}
	
	unichar next_char() {
		unichar c = input.get_char();
		advance();
		return c;
	}
	
	bool accept(unichar c) {
		if (input.get_char() == c) {
			advance();
			return true;
		}
		return false;
	}

	// Return true if the current token equals s.	
	bool match(string s) {
		char *p = token_start;
		char *q = s;
		while (*p != 0 && *q != 0 && *p == *q) {
			p = p + 1;
			q = q + 1;
		}
		return p == input && *q == 0;
	}
	
	Token read_token() {
		while (input != "") {
			token_start = input;
			token_start_pos = input_pos;
			unichar c = next_char();
			if (c.isspace())
				continue;
			if (c.isalpha() || c == '_') {		// identifier start
				while (true) {
					c = input.get_char();
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
					unichar d = input.get_char();
					if (d == '/') {    // single-line comment
						while (input != "" && next_char() != '\n')
							;
						continue;
					}
					if (d == '*') {	   // multi-line comment
						advance();	// move past '*'
						while (input != "") { 
							if (next_char() == '*' && input.get_char() == '/') {
								advance();	// move past '/'
								break;
							}
						}
						continue;
					}
					return Token.CHAR;
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
				case ',': return Token.COMMA;
				case '=': return Token.EQUALS;
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
		start = token_start_pos;
		end = input_pos;
		return t;
	}
	
	public bool eof() { return peek_token() == Token.EOF; }
	
	// Return the value of the last token peeked or retrieved, if it was an identifier.
	public string val() {
		size_t bytes = (char *) input - (char *) token_start;
		return token_start.ndup(bytes);
	} 
}

