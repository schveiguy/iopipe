/**
  Simple streams for use with iopipe
Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy
at http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.stream;

import std.range.primitives;

version(Have_io)
{
    import std.io;

    version(Posix)
    {
        /// Deprecated: use std.io directly
        deprecated alias IODev = IOObject!(File);

        /**
         * Construct an input stream based on the file descriptor
         *
         * params:
         * fd = The file descriptor to wrap
         *
         * Deprecated: Use https://code.dlang.org/io for low-level device i/o
         */
        deprecated("use std.io")
            auto openDev(int fd)
            {
                return ioObject(File(fd));
            }

        /**
         * Open a file by name.
         *
         * Deprecated: Use https://code.dlang.org/io for low-level device i/o
         */
        deprecated("use std.io")
            auto openDev(in char[] name, Mode mode = Mode.read | Mode.binary)
            {
                return ioObject(File(name, mode));
            }
    }
}


/**
 * A source that reads uninitialized data.
 */
struct NullDev
{
    /**
     * read the data. Always succeeds.
     */
    size_t read(T)(T buf) const
    {
        // null data doesn't matter
        return buf.length;
    }
}

/// Common instance of NullDev to use anywhere needed.
immutable NullDev nullDev;

/**
 * A source stream that always reads zeros, no matter what the data type is.
 */
struct ZeroDev
{
    size_t read(T)(T buf) const
    {
        // zero data
        buf[] = 0;
        return buf.length;
    }
}

/// Common instance of ZeroDev to use anywhere needed.
immutable ZeroDev zeroDev;

// helper for copying data from a src range into a buffer
private size_t copy(Src, Buf)(ref Src src, Buf buf) if(is(immutable(ElementEncodingType!Buf) == immutable(ElementEncodingType!Src)))
{
    // element compatible ranges. Use standard copying
    static if(is(Buf : T[], T) && is(Src : U[], U) && is(immutable(T) == immutable(U)))
    {
        // both dynamic arrays, use slice assign.
        auto n = src.length < buf.length ? src.length : buf.length;
        buf[0 .. n] = src[0 .. n];
        src = src[n .. $];
        return n;
    }
    else
    {
        size_t n = 0;
        while(n < buf.length && !src.empty)
        {
            buf[n++] = src.front;
            src.popFront;
        }
        return n;
    }
}

struct RangeInput(R) {
    private import std.traits: isNarrowString;
    private {
        R src;
        static if(is(ElementType!R == T[], T))
        {
            enum isRangeOfSlices = true;
            T[] data;
        }
        else
            enum isRangeOfSlices = false;
    }

    this(R src)
    {
        this.src = src;
        static if(isRangeOfSlices)
            if(!this.src.empty)
                data = this.src.front;
    }

    size_t read(Buf)(Buf buf) if (isNarrowString!Buf || isRandomAccessRange!Buf)
    {
        static if(is(typeof(copy(src, buf))))
        {
            return copy(src, buf);
        }
        else static if(isRangeOfSlices && is(typeof(copy(data, buf))))
        {
            size_t n = 0;
            while(n < buf.length && !src.empty)
            {
                n += copy(data, buf[n .. $]);
                if(data.empty)
                {
                    src.popFront;
                    data = src.empty ? null : src.front;
                }
            }
            return n;
        }
        else
            static assert(false, "Incompatible read for type `", Buf, "` and source range `", R, "`");
    }
}

/**
 * This is an adapter that provides a way to "read" data from an input range.
 * It can be used as an input source for any iopipe.
 *
 * This has a specialization for an input range that is a "range of slices"
 * type, since we can utilize slice assignment for the copy.
 */
auto rangeInput(R)(R range) if (isInputRange!R)
{
    return RangeInput!R(range);
}

unittest
{
    import std.range;
    import std.algorithm;
    import iopipe.bufpipe;
    import std.utf;


    // make a big range of characters
    {
        auto bigRange = repeat(only(repeat('a', 10), repeat('b', 10))).joiner.joiner.take(100000);
        auto inp = bigRange.rangeInput;
        inp.read(cast(char[])[]);
        auto pipe = bigRange.rangeInput.bufd!char;
        pipe.ensureElems();
        assert(equal(pipe.window.byChar, bigRange));
    }

    // try a range of slices
    {
        auto bigRange = repeat(only("aaaaaaaaaa", "bbbbbbbbbb"), 10000).joiner;
        auto inp = bigRange.rangeInput;
        inp.read(cast(char[])[]);
        auto pipe = bigRange.rangeInput.bufd!char;
        pipe.ensureElems();
        assert(equal(pipe.window, bigRange.joiner));
    }
}
