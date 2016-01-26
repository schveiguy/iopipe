/**
Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy at
           http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.textpipe;
import iopipe.bufpipe;

enum UTFType
{
    Unknown,
    UTF8,
    UTF16LE,
    UTF16BE,
    UTF32LE,
    UTF32BE
}

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

UTFType detectBOM(R)(R r)
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

auto doByteSwap(bool littleEndian, R)(R r)
{
    version(LittleEndian)
    {
        static if(littleEndian)
            return r;
        else
            return r.byteSwapper;
    }
    version(BigEndian)
    {
        static if(littleEndian)
            return r.byteSwapper;
        else
            return r;
    }
}


// call this after detecting the byte order/width
auto asText(UTFType b, Chain)(Chain chain)
{
    static if(b == UTFType.UTF8 || b == UTFType.Unknown)
        return chain.arrayConvert!(char);
    else static if(b == UTFType.UTF16LE)
    {
        return doByteSwap!(true)(chain.arrayConvert!(wchar));
    }
    else static if(b == UTFType.UTF16BE)
    {
        return doByteSwap!(false)(chain.arrayConvert!(wchar));
    }
    else static if(b == UTFType.UTF32LE)
    {
        return doByteSwap!(true)(chain.arrayConvert!(dchar));
    }
    else static if(b == UTFType.UTF32BE)
    {
        return doByteSwap!(false)(chain.arrayConvert!(dchar));
    }
    else
        static assert(0);
}

auto byLine(Chain)(Chain chain)
{
    alias Elem = typeof(chain.window[0..1]);
    struct Result
    {
        Chain chain;
        size_t checked;
        bool empty() { return chain.window.length == 0; }
        Elem front() { return chain.window[0 .. checked]; }
        void popFront()
        {
            chain.release(checked);
            checked = 0;
            int done = 0;
            while(!done)
            {
                foreach(i, dchar elem; chain.window[checked..$])
                {
                    if(done == 1)
                    {
                        done = 2;
                        checked += i;
                        break;
                    }
                    else if(elem == '\n')
                    {
                        done = 1;
                    }
                }
                if(done == 1)
                {
                    // ended at end of window
                    checked = chain.window.length;
                }
                else if(!done)
                {
                    // try and get more data
                    if(chain.extend(0) == 0)
                    {
                        // eof
                        checked = chain.window.length;
                        done = 2;
                    }
                }
            }
        }
    }
    auto r = Result(chain);
    r.popFront();
    return r;
}

auto textOutput(Chain)(Chain c)
{
    // create an output range of dchar/code units around c. We assume releasing and
    // extending c will properly output the data.
    alias CT = typeof(c.window[0]);
    static struct TextOutput
    {
        Chain chain;

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

    return TextOutput(c);
}

auto encodeText(UTFType enc, Chain)(Chain c)
{
    static if(enc == UTFType.UTF8)
    {
        static assert(is(typeof(c.window[0]) == char));
        return c.arrayConvert!ubyte;
    }
    else static if(enc == UTFType.UTF16LE)
    {
        static assert(is(typeof(c.window[0]) == wchar));
        return c.doByteSwap!(true).arrayConvert!ubyte;
    }
    else static if(enc == UTFType.UTF16BE)
    {
        static assert(is(typeof(c.window[0]) == wchar));
        return c.doByteSwap!(false).arrayConvert!ubyte;
    }
    else static if(enc == UTFType.UTF32LE)
    {
        static assert(is(typeof(c.window[0]) == dchar));
        return c.doByteSwap!(true).arrayConvert!ubyte;
    }
    else static if(enc == UTFType.UTF32BE)
    {
        static assert(is(typeof(c.window[0]) == dchar));
        return c.doByteSwap!(false).arrayConvert!ubyte;
    }
    else
        assert(0);
}
