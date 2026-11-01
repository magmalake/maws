"""`maws.jsonlite` — just enough JSON for AWS JSON-1.1 responses.

A flat, read-only tree, built like `xml.Document`: every value is a node id
into parallel arrays, objects and arrays link their children, and lookups
go by key or index. No recursive structs, no reflection, and no dependency
on a JSON package compiled for some other Mojo release — the binary
`emberjson` on the community channel lags the compiler, and the simdjson
binding needs a C++ toolchain.

Numbers are kept as their source text: Cost Explorer and Pricing send money
as *strings* anyway, and the caller decides when to `atof`.

Writing JSON is `json_str` (escape and quote a string); request bodies are
small enough to assemble by hand.
"""


comptime J_NULL = 0
comptime J_BOOL = 1
comptime J_NUMBER = 2
comptime J_STRING = 3
comptime J_ARRAY = 4
comptime J_OBJECT = 5

comptime NONE = -1


def _slice(b: Span[UInt8, _], start: Int, end: Int) -> String:
    return String(StringSlice(unsafe_from_utf8=b[start:end]))


def _append_utf8(mut out: List[UInt8], cp: Int):
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def json_str(s: String) -> String:
    """`s` as a quoted JSON string literal."""
    var out = List[UInt8]()
    out.append(34)
    var b = s.as_bytes()
    comptime hexd = "0123456789abcdef"
    for k in range(len(b)):
        var c = b[k]
        if c == 34 or c == 92:
            out.append(92)
            out.append(c)
        elif c == 10:
            out.append(92)
            out.append(110)
        elif c == 13:
            out.append(92)
            out.append(114)
        elif c == 9:
            out.append(92)
            out.append(116)
        elif c < 32:
            for x in "\\u00".as_bytes():
                out.append(x)
            out.append(hexd.as_bytes()[Int(c >> 4)])
            out.append(hexd.as_bytes()[Int(c & 0xF)])
        else:
            out.append(c)
    out.append(34)
    return String(StringSlice(unsafe_from_utf8=Span(out)))


struct JsonDoc(Movable, Sized):
    var _kind: List[Int]
    var _text: List[String]
    """String value, number text, `true`/`false`; empty otherwise."""
    var _key: List[String]
    """The member name when the parent is an object."""
    var _first: List[Int]
    var _last: List[Int]
    var _next: List[Int]
    var _count: List[Int]

    def __init__(out self):
        self._kind = List[Int]()
        self._text = List[String]()
        self._key = List[String]()
        self._first = List[Int]()
        self._last = List[Int]()
        self._next = List[Int]()
        self._count = List[Int]()

    def __len__(self) -> Int:
        return len(self._kind)

    @staticmethod
    def parse(src: String) raises -> JsonDoc:
        var doc = JsonDoc()
        var b = src.as_bytes()
        var p = Parser(b)
        p.skip_ws()
        _ = p.value(doc, NONE, String(""))
        p.skip_ws()
        if p.pos != len(b):
            p.fail("trailing content")
        return doc^

    def _add(
        mut self, kind: Int, text: String, parent: Int, key: String
    ) -> Int:
        var id = len(self._kind)
        self._kind.append(kind)
        self._text.append(text)
        self._key.append(key)
        self._first.append(NONE)
        self._last.append(NONE)
        self._next.append(NONE)
        self._count.append(0)
        if parent != NONE:
            if self._first[parent] == NONE:
                self._first[parent] = id
            else:
                self._next[self._last[parent]] = id
            self._last[parent] = id
            self._count[parent] += 1
        return id

    def root(self) -> Int:
        return 0

    def kind(self, node: Int) -> Int:
        return self._kind[node]

    def count(self, node: Int) -> Int:
        """Members of an object or elements of an array."""
        return self._count[node]

    def key(self, node: Int) -> String:
        return self._key[node]

    def children(self, node: Int) -> List[Int]:
        var out = List[Int]()
        if node == NONE:
            return out^
        var c = self._first[node]
        while c != NONE:
            out.append(c)
            c = self._next[c]
        return out^

    def get(self, node: Int, key: String) -> Int:
        """The member `key` of object `node`, or `NONE`."""
        if node == NONE or self._kind[node] != J_OBJECT:
            return NONE
        var c = self._first[node]
        while c != NONE:
            if self._key[c] == key:
                return c
            c = self._next[c]
        return NONE

    def at(self, node: Int, index: Int) -> Int:
        if node == NONE or self._kind[node] != J_ARRAY:
            return NONE
        var c = self._first[node]
        var i = 0
        while c != NONE:
            if i == index:
                return c
            c = self._next[c]
            i += 1
        return NONE

    def path(self, node: Int, path: String) -> Int:
        """`a/b/0/c` — object keys and array indices, `/`-separated."""
        var cur = node
        var parts = path.split("/")
        for k in range(len(parts)):
            if cur == NONE:
                return NONE
            var seg = String(parts[k])
            if seg == "":
                continue
            if self._kind[cur] == J_ARRAY:
                try:
                    cur = self.at(cur, atol(seg))
                except:
                    return NONE
            else:
                cur = self.get(cur, seg)
        return cur

    def text(self, node: Int, default: String = "") -> String:
        """A string's value or a number's source text."""
        if node == NONE or self._kind[node] == J_NULL:
            return default
        return self._text[node]

    def str(self, node: Int, key: String, default: String = "") -> String:
        return self.text(self.get(node, key), default)

    def num(self, node: Int, default: Float64 = 0.0) -> Float64:
        """A number, or a string holding one (how AWS sends money)."""
        if node == NONE:
            return default
        var k = self._kind[node]
        if k != J_NUMBER and k != J_STRING:
            return default
        try:
            return atof(self._text[node])
        except:
            return default


struct Parser:
    var b: List[UInt8]
    var pos: Int

    def __init__(out self, b: Span[UInt8, _]):
        self.b = List[UInt8](b)
        self.pos = 0

    def fail(self, msg: String) raises:
        raise Error("json: " + msg + " at byte " + String(self.pos))

    def skip_ws(mut self):
        while self.pos < len(self.b):
            var c = self.b[self.pos]
            if c == 32 or c == 9 or c == 10 or c == 13:
                self.pos += 1
            else:
                return

    def lit(mut self, word: StringSlice) raises:
        var w = word.as_bytes()
        if self.pos + len(w) > len(self.b):
            self.fail("unexpected end")
        for k in range(len(w)):
            if self.b[self.pos + k] != w[k]:
                self.fail("bad literal")
        self.pos += len(w)

    def string(mut self) raises -> String:
        # at the opening quote
        self.pos += 1
        var out = List[UInt8]()
        while True:
            if self.pos >= len(self.b):
                self.fail("unterminated string")
            var c = self.b[self.pos]
            if c == 34:
                self.pos += 1
                break
            if c != 92:
                out.append(c)
                self.pos += 1
                continue
            self.pos += 1
            if self.pos >= len(self.b):
                self.fail("unterminated escape")
            var e = self.b[self.pos]
            self.pos += 1
            if e == 34 or e == 92 or e == 47:
                out.append(e)
            elif e == 98:
                out.append(8)
            elif e == 102:
                out.append(12)
            elif e == 110:
                out.append(10)
            elif e == 114:
                out.append(13)
            elif e == 116:
                out.append(9)
            elif e == 117:
                var cp = self.hex4()
                if cp >= 0xD800 and cp <= 0xDBFF:
                    if (
                        self.pos + 1 < len(self.b)
                        and self.b[self.pos] == 92
                        and self.b[self.pos + 1] == 117
                    ):
                        self.pos += 2
                        var lo = self.hex4()
                        if lo < 0xDC00 or lo > 0xDFFF:
                            self.fail("bad surrogate pair")
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    else:
                        self.fail("lone surrogate")
                _append_utf8(out, cp)
            else:
                self.fail("bad escape")
        return String(StringSlice(unsafe_from_utf8=Span(out)))

    def hex4(mut self) raises -> Int:
        if self.pos + 4 > len(self.b):
            self.fail("short \\u escape")
        var v = 0
        for _ in range(4):
            var c = self.b[self.pos]
            var d: Int
            if c >= 48 and c <= 57:
                d = Int(c) - 48
            elif c >= 97 and c <= 102:
                d = Int(c) - 87
            elif c >= 65 and c <= 70:
                d = Int(c) - 55
            else:
                d = -1
            if d < 0:
                self.fail("bad \\u escape")
            v = v * 16 + d
            self.pos += 1
        return v

    def value(
        mut self, mut doc: JsonDoc, parent: Int, key: String
    ) raises -> Int:
        if self.pos >= len(self.b):
            self.fail("unexpected end")
        var c = self.b[self.pos]
        if c == 123:  # {
            var id = doc._add(J_OBJECT, String(""), parent, key)
            self.pos += 1
            self.skip_ws()
            if self.pos < len(self.b) and self.b[self.pos] == 125:
                self.pos += 1
                return id
            while True:
                self.skip_ws()
                if self.pos >= len(self.b) or self.b[self.pos] != 34:
                    self.fail("expected a member name")
                var k = self.string()
                self.skip_ws()
                if self.pos >= len(self.b) or self.b[self.pos] != 58:
                    self.fail("expected ':'")
                self.pos += 1
                self.skip_ws()
                _ = self.value(doc, id, k)
                self.skip_ws()
                if self.pos >= len(self.b):
                    self.fail("unterminated object")
                if self.b[self.pos] == 44:
                    self.pos += 1
                    continue
                if self.b[self.pos] == 125:
                    self.pos += 1
                    return id
                self.fail("expected ',' or '}'")
        if c == 91:  # [
            var id = doc._add(J_ARRAY, String(""), parent, key)
            self.pos += 1
            self.skip_ws()
            if self.pos < len(self.b) and self.b[self.pos] == 93:
                self.pos += 1
                return id
            while True:
                self.skip_ws()
                _ = self.value(doc, id, String(""))
                self.skip_ws()
                if self.pos >= len(self.b):
                    self.fail("unterminated array")
                if self.b[self.pos] == 44:
                    self.pos += 1
                    continue
                if self.b[self.pos] == 93:
                    self.pos += 1
                    return id
                self.fail("expected ',' or ']'")
        if c == 34:
            var s = self.string()
            return doc._add(J_STRING, s, parent, key)
        if c == 116:
            self.lit("true")
            return doc._add(J_BOOL, String("true"), parent, key)
        if c == 102:
            self.lit("false")
            return doc._add(J_BOOL, String("false"), parent, key)
        if c == 110:
            self.lit("null")
            return doc._add(J_NULL, String(""), parent, key)
        var start = self.pos
        while self.pos < len(self.b):
            var d = self.b[self.pos]
            if (
                (d >= 48 and d <= 57)
                or d == 45
                or d == 43
                or d == 46
                or d == 101
                or d == 69
            ):
                self.pos += 1
            else:
                break
        if self.pos == start:
            self.fail("unexpected character")
        return doc._add(
            J_NUMBER, _slice(Span(self.b), start, self.pos), parent, key
        )
