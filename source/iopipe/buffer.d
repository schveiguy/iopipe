/**
Copyright: Copyright Steven Schveighoffer 20011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy at
           http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer, Dmitry Olshansky
 */
module iopipe.buffer;

/**
 * Array-based buffer
 *
 * Based on concept by Dmitry Olshansky
 */
struct ArrayBuffer(T)
{
    static typeof(this) createDefault() {
        return typeof(this)(512, 8 * 1024);
    }

    static typeof(this) *allocateDefault() {
        return new typeof(this)(512, 8 * 1024);
    }

    this(size_t chunk, size_t initial) {
        import core.bitop : bsr;
        assert((chunk & (chunk - 1)) == 0 && chunk != 0);
        static assert(bsr(1) == 0);
        auto pageBits = bsr(chunk)+1;
        pageMask = (1<<pageBits)-1;
        //TODO: revisit with std.allocator
        buffer = new T[initial<<pageBits];
    }

    // get the valid data in the buffer
    @property auto window(){
        return buffer;
    }

    /**
     * toDiscard - number of bytes at the beginning of the buffer that aren't valid
     * valid - number of elements that are valid in the buffer (starting at 0)
     * buffer[toDiscard..valid] are valid data bytes
     * minBytes - minimum number of *extra* bytes requested besides the valid data that should be made available.
     */
    size_t extendAndFlush(size_t toDiscard, size_t valid, size_t minBytes)
    {
        import std.array : uninitializedArray;
        import std.algorithm.mutation : copy;
        import std.algorithm.comparison : max;
        size_t start = void;
        size_t end = void;
        if(toDiscard >= valid)
        {
            start = end = valid = 0;
        }
        else
        {
            start = toDiscard;
            end = valid;
            valid -= toDiscard;
        }
        // check number of bytes we can extend without reallocating
        if(buffer.length - valid >= minBytes)
        {
            // can just move data
            if(valid > 0)
                copy(buffer[start..end], buffer[0..valid]);
        }
        else
        {
            auto oldLen = buffer.length;
            auto newLen = max(valid + minBytes, oldLen * 14 / 10);
            newLen = (newLen + pageMask) & ~pageMask; //round up to page
            auto newbuf = uninitializedArray!(T[])(newLen);
            if (valid > 0) {
                // n + pageMask -> at least 1 page, no less then n
                copy(buffer[start .. end], newbuf[0 .. valid]);
            }
            buffer = newbuf;
        }
        
        return buffer.length - valid;
    }

private:
    T[] buffer;
    size_t pageMask; //bit mask - used for fast rounding to multiple of page
}
