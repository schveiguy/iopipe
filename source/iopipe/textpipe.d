/**
Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy at
           http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.textpipe;
import iopipe.bufpipe;
import iopipe.traits;
import std.range: isRandomAccessRange, hasLength, ElementType, ElementEncodingType;
import std.traits: Unqual, isSomeChar, isDynamicArray, isIntegral;

/**
 * Used to specify stream type
 */
enum UTFType
{
    Unknown,
    UTF8,
    UTF16LE,
    UTF16BE,
    UTF32LE,
    UTF32BE
}

/**
 * Aliased to code unit type of a specified stream type.
 *
 * `Unknown` is specified as char (UTF8 is the default)
 */
template CodeUnit(UTFType u)
{
    static if(u == UTFType.Unknown || u == UTFType.UTF8)
        alias CodeUnit = char;
    else static if(u == UTFType.UTF16LE || u == UTFType.UTF16BE)
        alias CodeUnit = wchar;
    else static if(u == UTFType.UTF32LE || u == UTFType.UTF32BE)
        alias CodeUnit = dchar;
    else
        static assert(0);
}

/**
 * Using the given random access range of bytes, determine the stream width.
 * This does not advance the range past the BOM.
 *
 * Params:
 *    r - Range in which to detect BOM. Must be a random access range with
 *        element type of ubyte. Cannot be an infinite range.
 *
 * Returns:
 *    Instance of UTFType indicating what the BOM decoding implies.
 */
UTFType detectBOM(R)(R r) if (isRandomAccessRange!R && hasLength!R && is(ElementType!R : const(ubyte)))
{
    if(r.length >= 2)
    {
        if(r[0] == 0xFE && r[1] == 0xFF)
            return UTFType.UTF16BE;
        if(r[0] == 0xFF && r[1] == 0xFE)
        {
            if(r.length >= 4 && r[2] == 0 && r[3] == 0)
            {
                // most likely UTF32
                return UTFType.UTF32LE;
            }
            return UTFType.UTF16LE;
        }

        if(r.length >= 3 && r[0] == 0xEF && r[1] == 0xBB && r[2] == 0xBF)
            return UTFType.UTF8;
        if(r.length >= 4 && r[0] == 0 && r[1] == 0 && r[2] == 0xFE && r[3] == 0xFF)
            return UTFType.UTF32BE;
    }
    return UTFType.Unknown;
}

@safe unittest
{
    with(UTFType)
    {
        ubyte[] BOM = [0xFE, 0XFF, 0xFE, 0, 0, 0xFE, 0xFF, 0xEF, 0xBB, 0xBF];
        assert(BOM.detectBOM == UTF16BE);
        assert(BOM[1 .. 4].detectBOM == UTF16LE);
        assert(BOM[1 .. 5].detectBOM == UTF32LE);
        assert(BOM[3 .. $].detectBOM == UTF32BE);
        assert(BOM[7 .. $].detectBOM == UTF8);
        assert(BOM[4 .. $].detectBOM == Unknown);
    }
}

struct DecodeableWindow(Chain, CodeUnitType)
{
    Chain chain;
    ubyte partial;
    auto window() { return chain.window[0 .. $-partial]; }
    void release(size_t elements) { chain.release(elements); }
    private void determinePartial()
    {
        static if(is(CodeUnitType == char))
        {
            auto w = chain.window;
            // ends on a multi-char sequence. Ensure it's valid.
            // find the encoding
ee_outer:
            foreach(ubyte i; 1 .. 4)
            {
                import core.bitop : bsr;
                if(w.length < i)
                {
                    // either no data, or invalid sequence.
                    if(i > 1)
                    {
                        // TODO: throw some error?
                    }
                    partial = 0;
                    break ee_outer;
                }
                immutable highestBit = bsr(~w[$ - i] & 0x0ff);
                switch(highestBit)
                {
                case 7:
                    // ascii character
                    if(i > 1)
                    {
                        // TODO: throw some error?
                    }
                    partial = 0;
                    break ee_outer;
                case 6:
                    // need to continue looking
                    break;
                case 3: .. case 5:
                        // 5 -> 2 byte sequence
                        // 4 -> 3 byte sequence
                        // 3 -> 4 byte sequence
                        if(i + highestBit == 7)
                            // complete sequence, let it pass.
                            partial = 0;
                        else
                            // skip these, the whole sequence isn't there yet.
                            partial = i;
                        break ee_outer;
                default:
                        // invalid sequence, let it fail
                        // TODO: throw some error?
                        partial = 0;
                        break ee_outer;
                }
            }
        }
        else // wchar
        {
            // if the last character is in 0xD800 - 0xDBFF, then it is
            // the first wchar of a surrogate pair. This means we must
            // leave it off the end.
            partial = chain.window.length > 0 && (chain.window[$-1] & 0xFC00) == 0xD800 ? 1 : 0;
        }
    }
    size_t extend(size_t elements)
    {
        auto origWindowSize = window.length;
        cast(void)chain.extend(elements > partial ? elements - partial : elements);
        determinePartial();
        // TODO: may need to loop if we are getting one char at a time.
        return window.length - origWindowSize;
    }

    mixin implementValve!chain;
}

/**
 * Wraps a text-based iopipe to make sure all code units are decodeable.
 *
 * When an iopipe is made up of character types, in some cases a slice of the
 * window may not be completely decodeable. For example, a wchar iopipe may
 * have only one half of a surrogate pair at the end of the window.
 *
 * This function generates an iopipe that only allows completely decodeable
 * sequences to be released to the next iopipe.
 *
 * Params:
 *    Chain c - The iopipe whose element type is one of char, wchar, or dchar.
 * 
 * Returns:
 *    An appropriate iopipe that ensures decodeability. Note that dchar iopipes
 *    are always decodeable, so the result is simply a return of the input. 
 */
auto ensureDecodeable(Chain)(Chain c) if (isIopipe!Chain && isSomeChar!(ElementEncodingType!(WindowType!Chain)))
{
    import std.traits: Unqual;
    alias CodeUnitType = Unqual!(ElementEncodingType!(WindowType!Chain));

    // need to stop chaining if the last thing was an ensureDecodable. Of
    // course, it's very hard to check if the type is a DecodeableWindow. What
    // we do is pretend to wrap c's upstream chain, and see if it results in
    // the exact type we were passed. If this is the case, then it must be a
    // type that was wrapped with a DecodableWindow.
    static if(is(CodeUnitType == dchar))
    {
        // always decodeable
        return c;
    }
    else static if(__traits(hasMember, Chain, "chain") &&
                   is(typeof(.ensureDecodeable(c.chain)) == Chain))
    {
        return c;
    }
    else
    {
        auto r = DecodeableWindow!(Chain, CodeUnitType)(c);
        r.determinePartial();
        return r;
    }
}

unittest
{
    // check that ensureDecodeable just returns itself when called twice
    auto str = "hello";
    auto d1 = str.ensureDecodeable;
    auto d2 = d1.ensureDecodeable;
    static assert(is(typeof(d1) == typeof(d2)));
}

/**
 * Given an ioPipe whose window is a buffer that is a dynamic array of data of
 * integral type, performs the proper transformations in order to get a buffer
 * of valid char, wchar, or dchar elements, depending on the provided encoding.
 * This function is useful for when you have data from a raw source (such as a
 * file or stream) that you have determined or know is really a stream of UTF
 * data.
 *
 * If the data must be byte-swapped, then it must be mutable. Otherwise,
 * immutable or const data is allowed.
 *
 * Params:
 *    enc = The assumed encoding of the text pipe.
 *    Chain = The chain to assume the encoding for. This MUST have a dynamic
 *            array type for its window, and the elements must be integral.
 * Returns:
 *    An appropriate iopipe that has a window of the appropriate character type
 *    (`char`, `wchar`, or `dchar`) for the assumed encoding. The window will
 *    be set up so its elements are properly byte-ordered for the compiled
 *    platform.
 */
auto assumeText(UTFType enc = UTFType.UTF8, Chain)(Chain c) if (isIopipe!Chain && isDynamicArray!(WindowType!Chain) && isIntegral!(ElementEncodingType!(WindowType!Chain)))
{
    static if(enc == UTFType.UTF8 || enc == UTFType.Unknown)
        return c.arrayCastPipe!char;
    else static if(enc == UTFType.UTF16LE || enc == UTFType.UTF32LE)
    {
        return c.arrayCastPipe!(CodeUnit!enc).byteSwapper!true;
    }
    else static if(enc == UTFType.UTF16BE || enc == UTFType.UTF32BE)
    {
        return c.arrayCastPipe!(CodeUnit!enc).byteSwapper!false;
    }
    else
        static assert(0);
}

unittest
{
    import std.algorithm : equal;
    import core.bitop : bswap;
    // standard char array, casted to ubyte (typical case)
    ubyte[] str1 = ['h', 'e', 'l', 'l', 'o'];
    
    auto p1 = str1.assumeText!(UTFType.UTF8);
    static assert(is(WindowType!(typeof(p1)) == char[]));
    assert("hello".equal(p1.window));

    // build a byte-swapped array for "hello"
    uint[] str2 = ['h', 'e', 'l', 'l', 'o'];
    foreach(ref i; str2)
        i = bswap(i);

    // encoding should be utf32, in non-native endianness.
    version(BigEndian)
    {
        enum encType = UTFType.UTF32LE;
    }
    else
    {
        enum encType = UTFType.UTF32BE;
    }

    auto p2 = str2.assumeText!encType;
    static assert(is(WindowType!(typeof(p2)) == dchar[]));
    assert("hello".equal(p2.window));
}

private struct DelimitedTextPipe(Chain)
{
    alias CodeUnitType = Unqual!(typeof(Chain.init.window[0]));
    private
    {
        Chain chain;
        size_t checked;
        size_t _segments;
        bool endsWithDelim;
        CodeUnitType[dchar.sizeof / CodeUnitType.sizeof] delimElems;

        static if(is(CodeUnitType == dchar))
        {
            enum validDelimElems = 1;
            enum skippableElems = 1;
        }
        else
        {
            // number of elements in delimElems that are valid
            ubyte validDelimElems;
            // number of elements that can be skipped if the sequence fails
            // to match. This basically is the number of elements that are
            // not the first element (except the first element of course).
            ubyte skippableElems;
        }
    }

    auto window() { return chain.window[0 .. checked]; }
    ubyte delimTrailer() { return endsWithDelim ? validDelimElems : 0; }
    void release(size_t elements)
    {
        checked -= elements;
        chain.release(elements);
    }

    size_t extend(size_t elements = 0)
    {
        auto newChecked = checked;
        endsWithDelim = false;
        if(validDelimElems == 1)
        {
            // simple scan per element
byline_outer_1:
            do
            {
                auto w = chain.window;
                immutable t = delimElems[0];
                static if(isDynamicArray!(WindowType!(Chain)))
                {
                    auto p = w.ptr + newChecked;
                    static if(CodeUnitType.sizeof == 1)
                    {
                        // can use memchr
                        import core.stdc.string: memchr;
                        auto delimp = memchr(p, t, w.length - newChecked);
                        if(delimp != null)
                        {
                            // found it
                            newChecked = delimp + 1 - w.ptr;
                            endsWithDelim = true;
                            break byline_outer_1;
                        }
                    }
                    else
                    {
                        auto e = w.ptr + w.length;
                        while(p < e)
                        {
                            if(*p++ == t)
                            {
                                // found it
                                newChecked = p - w.ptr;
                                endsWithDelim = true;
                                break byline_outer_1;
                            }
                        }
                    }
                    newChecked = w.length;
                }
                else
                {
                    while(newChecked < w.length)
                    {
                        if(w[newChecked] == t)
                        {
                            // found it.
                            ++newChecked;
                            endsWithDelim = true;
                            break byline_outer_1;
                        }
                        ++newChecked;
                    }
                }
            } while(chain.extend(elements) != 0);
        }
        else // shouldn't be compiled in the case of dchar
        {
            // need to check multiple elements
byline_outer_2:
            while(true)
            {
                // load everyhing into locals to avoid unnecessary dereferences.
                auto w = chain.window;
                auto se = skippableElems;
                auto ve = validDelimElems;
                while(newChecked + ve <= w.length)
                {
                    size_t i = 0;
                    auto ptr = delimElems.ptr;
                    while(i < ve)
                    {
                        if(w[newChecked + i] != *ptr++)
                        {
                            newChecked += i < se ? i + 1 : se;
                            continue byline_outer_2;
                        }
                        ++i;
                    }
                    // found it
                    endsWithDelim = true;
                    newChecked += ve;
                    break byline_outer_2;
                }

                // need to read more data
                if(chain.extend(elements) == 0)
                {
                    newChecked = chain.window.length;
                    break;
                }
            }
        }

        auto prevChecked = checked;
        if(checked != newChecked)
        {
            ++_segments;
            checked = newChecked;
        }
        return checked - prevChecked;
    }

    size_t segments() { return _segments; }
}

/**
 * Process a given text iopipe by a given code point delimeter. The only
 * behavior that changes from the input pipe is that extensions to the window
 * deliever exactly one more delimited segment of text.
 *
 * Params:
 *    c = The input text iopipe. This must have a window whose elements are
 *        valid character types.
 *    delim = The code point with which to delimit the text. Each extension to
 *        the iopipe will either end on this delimiter, or will be the last
 *        segment in the pipe.
 * Returns:
 *    An iopipe that behaves as described above.
 */
auto delimitedText(Chain)(Chain c, dchar delim = '\n')
   if(isIopipe!Chain &&
      isSomeChar!(ElementEncodingType!(WindowType!Chain)))
{
    import std.traits: Unqual;
    auto result = DelimitedTextPipe!(Chain)(c);
    // set up the delimeter
    static if(is(result.CodeUnitType == dchar))
    {
        result.delimElems[0] = delim;
    }
    else
    {
        import std.utf: encode;
        result.validDelimElems = cast(ubyte)encode(result.delimElems, delim);
        result.skippableElems = 1; // need to be able to skip at least one element
        foreach(x; result.delimElems[1 .. result.validDelimElems])
        {
            if(x == result.delimElems[0])
                break;
            ++result.skippableElems;
        }
    }
    return result;
}

unittest
{
    auto p = "hello world, this is a test".delimitedText(' ');
    p.extend;
    assert(p.window == "hello ");
    p.extend;
    assert(p.window == "hello world, ");
    p.extend;
    assert(p.window == "hello world, this ");
    assert(p.segments == 3);
    assert(p.delimTrailer == 1);
    p.process();
    assert(p.segments == 6);
    assert(p.delimTrailer == 0);
}

/**
 * A convenience wrapper for delimitedText that uses the newline character '\n'
 * to delimit the segments. Equivalent to `delimitedText(c, '\n');`
 *
 * Params:
 *    c = The input text iopipe. This must have a window whose elements are
 *        valid character types.
 * Returns:
 *    A line delimited iopipe.
 */
auto byLine(Chain)(Chain c)
{
    return delimitedText(c, '\n');
}

// same as a normal range, but we don't return the delimiter.
// Note that the Chain MUST be a ByDelim iopipe.
private struct NoDelimRange(Chain)
{
    Chain chain;
    ubyte delimElems;
    bool empty() { return chain.window.length == 0; }
    auto front() { return chain.window[0 .. $ - delimElems]; }
    void popFront()
    {
        chain.release(chain.window.length);
        chain.extend(0);
        delimElems = chain.delimTrailer;
    }
}

/**
 * Given a text iopipe, returns a range based on splitting the text by a given
 * code point. This has the advantage over `delimitedText.asRange` in that the
 * delimiter can be hidden.
 *
 * Params:
 *     KeepDelimiter = If true, then the delimiter is included in each element
 *        of the range (if present from the original iopipe).
 *     c = The iopipe to range-ify.
 *     delim = The dchar to use for delimiting.
 * Returns:
 *     An input range whose elements are the delimited text segments, with or
 *     without delimiters as specified by the KeepDelimiter boolean.
 */

auto byDelimRange(bool KeepDelimiter = false, Chain)(Chain c, dchar delim)
   if(isIopipe!Chain &&
      is(Unqual!(ElementType!(WindowType!Chain)) == dchar))
{
    auto p = c.delimitedText(delim);
    static if(KeepDelimiter)
    {
        // just use standard input range adapter
        return p.asInputRange;
    }
    else
    {
        auto r = NoDelimRange!(typeof(p))(p);
        // pre-fetch first line
        r.popFront();
        return r;
    }
}

/**
 * Convenience wrapper for byDelimRange that uses the newline character '\n' as
 * the delimiter. Equivalent to `byDelimRange!(KeepDelimiter)(c, '\n');
 *
 * Params:
 *     KeepDelimiter = If true, then the delimiter is included in each element
 *        of the range (if present from the original iopipe).
 *     c = The iopipe to range-ify.
 * Returns:
 *     An input range whose elements are lines of text from the input iopipe,
 *     with or without delimiters as specified by the KeepDelimiter boolean.
 */

auto byLineRange(bool KeepDelimiter = false, Chain)(Chain c)
{
    return byDelimRange!(KeepDelimiter)(c, '\n');
}

unittest
{
    import std.algorithm : equal;
    assert("hello\nworld".byLineRange.equal(["hello", "world"]));
    assert("hello\nworld".byLineRange!true.equal(["hello\n", "world"]));
    assert("\nhello\nworld".byLineRange.equal(["", "hello", "world"]));
    assert("\nhello\nworld".byLineRange!true.equal(["\n", "hello\n", "world"]));
    assert("\nhello\nworld\n".byLineRange.equal(["", "hello", "world"]));
    assert("\nhello\nworld\n".byLineRange!true.equal(["\n", "hello\n", "world\n"]));
}

static struct TextOutput(Chain)
{
    Chain chain;
    alias CT = typeof(Chain.init.window[0]);

    // TODO: allow putting of strings

    void put(A)(A c)
    {
        import std.utf;
        static if(A.sizeof == CT.sizeof)
        {
            // output the data directly to the output stream
            if(chain.ensureElems(1) == 0)
                assert(0);
            chain.window[0] = c;
            chain.release(1);
        }
        else
        {
            static if(is(CT == char))
            {
                static if(is(A : const(wchar)))
                {
                    // A is a wchar.  Make sure it's not a surrogate pair
                    // (that it's a valid dchar)
                    if(!isValidDchar(c))
                        assert(0);
                }
                // convert the character to utf8
                if(c <= 0x7f)
                {
                    if(chain.ensureElems(1) == 0)
                        assert(0);
                    chain.window[0] = cast(char)c;
                    chain.release(1);
                }
                else
                {
                    char[4] buf = void;
                    auto idx = 3;
                    auto mask = 0x3f;
                    dchar c2 = c;
                    while(c2 > mask)
                    {
                        buf[idx--] = 0x80 | (c2 & 0x3f);
                        c2 >>= 6;
                        mask >>= 1;
                    }
                    buf[idx] = (c2 | (~mask << 1)) & 0xff;
                    auto x = buf.ptr[idx..buf.length]; 
                    if(chain.ensureElems(x.length) < x.length)
                        assert(0);
                    chain.window[0 .. x.length] = x;
                    chain.release(x.length);
                }
            }
            else static if(is(CT == wchar))
            {
                static if(is(A : const(char)))
                {
                    // this is a utf-8 character, only works if it's an
                    // ascii character
                    if(c > 0x7f)
                        throw new Exception("invalid character output");
                }
                // convert the character to utf16
                assert(isValidDchar(c));
                if(c < 0xFFFF)
                {
                    if(chain.ensureElems(1) == 0)
                        assert(0);
                    chain.window[0] = cast(wchar)c;
                    chain.release(1);
                }
                else
                {
                    if(chain.ensureElems(2) < 2)
                        assert(0);
                    wchar[2] buf = void;
                    dchar dc = c - 0x10000;
                    buf[0] = cast(wchar)(((dc >> 10) & 0x3FF) + 0xD800);
                    buf[1] = cast(wchar)((dc & 0x3FF) + 0xDC00);
                    chain.window[0..2] = buf;
                    chain.release(2);
                }
            }
            else static if(is(CT == dchar))
            {
                static if(is(A : const(char)))
                {
                    // this is a utf-8 character, only works if it's an
                    // ascii character
                    if(c > 0x7f)
                        throw new Exception("invalid character output");
                }
                else static if(is(A : const(wchar)))
                {
                    // A is a wchar.  Make sure it's not a surrogate pair
                    // (that it's a valid dchar)
                    if(!isValidDchar(c))
                        throw new Exception("invalid character output");
                }
                // converting to utf32, just write directly
                if(chain.ensureElems(1) == 0)
                    assert(0);
                chain.window[0] = c;
                chain.release(1);
            }
            else
                static assert(0, "invalid types used for output stream, " ~ CT.stringof ~ ", " ~ C.stringof);
        }
    }
}

/**
 * Take a text-based iopipe and turn it into an output range of `dchar`. Note
 * that the iopipe must be an output iopipe, not an input one. In other words,
 * a `textOutput` result doesn't output its input, it uses its input as a place
 * to deposit data.
 *
 * The given iopipe window will be written to, then data that is ready to be
 * output is released. It is expected that the iopipe will use this mechanism
 * to actually know which data to output. See the example for more information.
 *
 * Params:
 *     c = The output iopipe that can be used to put dchars into.
 * Returns:
 *     An output range that can accept all forms of text data for output.
 */
auto textOutput(Chain)(Chain c)
{
    // create an output range of dchar/code units around c. We assume releasing and
    // extending c will properly output the data.

    return TextOutput!Chain(c);
}

///
unittest
{
    import std.range : put;
    // use a writeable buffer as output.
    char[256] buffer;
    size_t written = 0;

    // this helps us see how many chars are written.
    struct LocalIopipe
    {
        char[] window;
        void release(size_t elems)
        {
            window.release(elems);
            written += elems;
        }
        size_t extend(size_t elems) { return 0; }
    }
    auto oRange = LocalIopipe(buffer[]).textOutput;
    put(oRange, "hello, world");

    // written is updated whenever the iopipe is released
    assert(buffer[0 .. written] == "hello, world");
}

/**
 * Convert iopipe of one text type into an iopipe for another type. Performs
 * conversions at the code-point level. If specified, the resulting iopipe will
 * ensure there is a BOM at the beginning of the iopipe. This is useful if
 * writing to storage.
 *
 * If no conversion is necessary, and no BOM is required, the original iopipe
 * is returned.
 *
 * Params:
 *     Char = The desired character type in the resulting iopipe. Must be one
 *           of char, wchar, or dchar.
 *     ensureBOM = If true, the resulting iopipe will ALWAYS have a byte order
 *           mark at the beginning of the stream. At the moment this is
 *           accomplished by copying all the data from the original iopipe to
 *           the new one. A better mechanism is being worked on.
 *     chain = The source iopipe.
 * Returns:
 *     An iopipe which fulfills the given requirements.
 *
 */
auto convertText(Char = char, bool ensureBOM = false, Chain)(Chain chain) if (isSomeChar!Char)
{
    static if(!ensureBOM && is(ElementEncodingType!(WindowType!(Chain)) == Char))
        return chain;
    else
        return chain.textConverter!ensureBOM.bufd!Char;
}

unittest
{
    // test converting char[] to wchar[]
    auto inpipe = "hello";
    immutable(ushort)[] expected = cast(immutable(ushort)[])"\ufeffhello"w;
    auto wpipe = inpipe.convertText!wchar;
    static assert(is(WindowType!(typeof(wpipe)) == wchar[]));

    wpipe.extend(100);// fill the pipe
    assert(wpipe.window.length == 5);
    assert(cast(ushort[])wpipe.window == expected[1 .. $]);

    // ensure the BOM
    auto wpipe2 = inpipe.convertText!(wchar, true);
    wpipe2.extend(100);
    assert(wpipe2.window.length == 6);
    assert(cast(ushort[])wpipe2.window == expected);
}


/**
 * A converter to allow conversion into any other type of text.
 *
 * The converter does 2 things. First and foremost, it adds a read function
 * that allows conversion into any other width of text. The read function
 * converts as much text as possible into the given format, extending the base
 * iopipe as necessary.
 *
 * The second thing that it does is potentially add a BOM character to the
 * beginning of the text. It was decided to add this here, since you are likely
 * already copying data from one iopipe into another. However, in future
 * versions, this capability may go away, as we can do this elsewhere with less
 * copying. So expect this API to change.
 */
template textConverter(bool ensureBOM = false, Chain)
{
    struct TextConverter
    {
        Chain chain;
        static if(ensureBOM)
        {
            bool atBeginning = true;

            auto release(size_t elems)
            {
                atBeginning = atBeginning && elems == 0;
                return chain.release(elems);
            }
        }

        size_t read(Char)(Char[] buf)
        {
            alias SrcChar = ElementEncodingType!(WindowType!(Chain));
            if(buf.length == 0)
                return 0;
            // first step, check to see if the first code point is a BOM
            size_t result = 0;
            static if(ensureBOM)
            {
                if(atBeginning)
                {
                    // utf8 bom is 3 code units, in other char types, it's only 1.
                    bool addBOM = true;
                    static if(is(Unqual!SrcChar == char))
                    {
                        if(chain.window.length < 3)
                            chain.extend(0);
                        if(chain.window.length == 0)
                            return 0; // special case, don't insert a BOM for a blank file.
                        if(chain.window.length >= 3 &&
                           chain.window[0] == 0xef &&
                           chain.window[1] == 0xbb &&
                           chain.window[2] == 0xbf)
                        {
                            addBOM = false;
                        }
                    }
                    else
                    {
                        if(chain.window.length < 1)
                            if(chain.extend(0) == 0)
                                return 0; // special case, don't insert a BOM for a blank file.
                        if(chain.window[0] == 0xfeff)
                            addBOM = false;
                    }

                    if(addBOM)
                    {
                        // write the BOM to the given buffer
                        static if(is(Char == char))
                        {
                            buf[0] = 0xef;
                            buf[1] = 0xbb;
                            buf[2] = 0xbf;

                            result = 3;
                            buf = buf[3 .. $];
                        }
                        else
                        {
                            buf[0] = 0xfeff;
                            result = 1;
                            buf = buf[1 .. $];
                        }
                    }
                }
            }
            static if(is(Unqual!Char == Unqual!SrcChar))
            {
                import std.algorithm.mutation: copy;
                import std.algorithm.comparison: max;
                // try an extend when window length gets to be less than read size.
                if(chain.window.length < buf.length)
                    chain.extend(buf.length - chain.window.length);
                if(chain.window.length == 0)
                    // no more data
                    return 0;
                immutable len = max(chain.window.length, buf.length);
                copy(chain.window[0 .. len], buf[0 .. len]);
                chain.release(len);
                return result + len;
            }
            else
            {
                // need to transcode each code point.
                import std.utf;
                auto win = chain.window;
                size_t pos = 0;
                bool didExtend = false;
                bool eof = false;
                while(buf.length > 0)
                {
                    enum minValidElems = is(Unqual!Char == dchar) ? 1 : 4;
                    if(!eof && pos + minValidElems > chain.window.length)
                    {
                        if(!didExtend)
                        {
                            didExtend = true;
                            // give the upstream pipe some buffer space
                            chain.release(pos);
                            pos = 0;
                            if(chain.extend(0))
                            {
                                win = chain.window;
                                continue;
                            }
                            win = chain.window;
                            // else, we aren't going to get any more data. decode as needed.
                            eof = true;
                        }
                        else
                            // don't decode any more. We can wait until next time.
                            break;
                    }
                    if(pos == win.length)
                        // end of the stream
                        break;
                    // decode a code point
                    auto oldPos = pos;
                    dchar dc;
                    dc = decode(win, pos);
                    // encode the dchar into a new item
                    Char[dchar.sizeof / Char.sizeof] encoded;
                    auto nChars = encode(encoded, dc);
                    if(nChars > buf.length)
                    {
                        // read as much as we could.
                        pos = oldPos;
                        break;
                    }
                    if(nChars == 1)
                        buf[0] = encoded[0];
                    else
                        buf[0 .. nChars] = encoded[0 .. nChars];
                    result += nChars;
                    buf = buf[nChars .. $];
                }

                // release the chain data that we have processed.
                chain.release(pos);
                return result;
            }
        }
        alias chain this;
    }

    auto textConverter(Chain c)
    {
        return TextConverter(c);
    }
}

/**
 * Encode a given text iopipe into the desired encoding type. The resulting
 * iopipe's element type is ubyte, with the bytes ready to be written to a
 * storage device.
 *
 * Params:
 *     enc = The encoding type to use.
 *     c = The source iopipe. Must be an iopipe where the window type's element
 *          type is text based.
 * Returns:
 *     A ubyte iopipe that represents the encoded version of the input iopipe
 *     based on the provided encoding.
 */
auto encodeText(UTFType enc = UTFType.UTF8, Chain)(Chain c)
{
    auto converted = c.convertText!(CodeUnit!enc);

    static if(enc == UTFType.UTF8)
    {
        return converted.arrayCastPipe!ubyte;
    }
    else static if(enc == UTFType.UTF16LE || enc == UTFType.UTF32LE)
    {
        return converted.byteSwapper!(true).arrayCastPipe!ubyte;
    }
    else static if(enc == UTFType.UTF16BE || enc == UTFType.UTF32BE)
    {
        return converted.byteSwapper!(false).arrayCastPipe!ubyte;
    }
    else
        assert(0);
}

unittest
{
    import core.bitop : bswap;
    // ensure that we properly byteswap.
    auto input = "hello";

    version(BigEndian)
        enum encodingType = UTFType.UTF32LE;
    else
        enum encodingType = UTFType.UTF32BE;

    auto testme = input.encodeText!encodingType;
    static assert(is(WindowType!(typeof(testme)) == ubyte[]));

    uint[] expected = cast(uint[])"hello"d.dup;
    foreach(ref v; expected) v = bswap(v);

    testme.extend(100);
    assert(testme.window == cast(ubyte[])expected);
}

/**
 * Given a template function, and an input chain of encoded text data, this
 * function will detect the encoding of the input chain, and convert that
 * runtime value into a compile-time parameter to the given function. Useful
 * for writing code that needs to handle all the forms of text encoding.
 *
 * Use the encoding type as a parameter to assumeText to get an iopipe of
 * `char`, `wchar`, or `dchar` elements for processing.
 *
 * Note that func must return the same type no matter how it's called, as the
 * BOM detection and calling is done at runtime. Given that there are 5
 * different encodings that iopipe handles, you will have 6 instantiations of
 * the function, no matter whether the input contains that encoding or not.
 *
 * Params:
 *     func - The template function to call.
 *     UnknownIsUTF8 - If true, then an undetected encoding will be passed as
 *          UTF8 to your function. Otherwise, the Unknown encoding will be passed.
 *     c - The iopipe input chain that should have encoded text in it.
 *     args - Any optional args to pass to the function.
 * Returns:
 *     The return value from func.
 */
auto ref runWithEncoding(alias func, bool UnknownIsUTF8 = true, Chain, Args...)(Chain c, auto ref Args args)
    if(isIopipe!Chain && is(typeof(detectBOM(c.window))))
{
    // first, detect the encoding
    c.ensureElems(4);
    import std.traits: EnumMembers;
    auto bom = c.window.detectBOM;
    final switch(bom)
    {
        // TODO: static foreach should work here, but gives "unreachable statement"
        /*static*/ foreach(enc; EnumMembers!UTFType)
        {
        case enc:
            static if(UnknownIsUTF8 && enc == UTFType.Unknown)
                goto case UTFType.UTF8;
            else
                return func!(enc)(c, args);
        }
    }
}
