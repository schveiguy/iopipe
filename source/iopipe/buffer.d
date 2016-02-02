/**
Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy at
           http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer, Dmitry Olshansky
 */
module iopipe.buffer;
import std.experimental.allocator : IAllocator;

/**
 * Array-based buffer
 *
 * Based on concept by Dmitry Olshansky
 */
struct ArrayBuffer(T)
{
    // get the valid data in the buffer
    @property auto window(){
        return buffer;
    }

    /**
     * toDiscard - number of bytes at the beginning of the buffer that aren't valid
     * valid - number of elements that are valid in the buffer (starting at 0)
     * buffer[toDiscard..valid] are valid data bytes
     * minElements - minimum number of *extra* elements requested besides the
     * valid data that should be made available.
     */
    size_t extendAndFlush(size_t toDiscard, size_t valid, size_t minElements)
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
        if(buffer.length - valid >= minElements)
        {
            // can just move data
            if(valid > 0)
                copy(buffer[start..end], buffer[0..valid]);
        }
        else
        {
            auto oldLen = buffer.length;
            if(oldLen == 0)
                oldLen = INITIAL_LENGTH; // need to start somewhere.
            auto newLen = max(valid + minElements, oldLen * 14 / 10);
            auto newbuf = uninitializedArray!(T[])(newLen);
            if (valid > 0) {
                copy(buffer[start .. end], newbuf[0 .. valid]);
            }
            buffer = newbuf;
        }
        
        return buffer.length - valid;
    }

private:
    T[] buffer;
    enum size_t INITIAL_LENGTH = 128;
}

/**
 * Same as array buffer, but uses a custom allocator.
 *
 * Note that this will likely be worse performing for GCAllocator since it has
 * no concept of disabling scanning (as most ubyte buffers would).
 */
struct AllocatorBuffer(T, Allocator = IAllocator)
{
    this(Allocator allocator) {
        theAllocator = allocator;
    }

    // get the valid data in the buffer
    @property auto window(){
        return buffer;
    }

    /**
     * Extend the existing buffer a certain number of bytes, while flushing data
     * toDiscard - number of bytes at the beginning of the buffer that aren't valid
     * valid - number of elements that are valid in the buffer (starting at 0)
     * buffer[toDiscard..valid] are valid data bytes
     * minElements - minimum number of *extra* elements requested besides the
     * valid data that should be made available.
     */
    size_t extendAndFlush(size_t toDiscard, size_t valid, size_t minElements)
    {
        import std.algorithm.mutation : copy;
        import std.algorithm.comparison : max;
        import std.traits : hasMember;
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
        if(buffer.length - valid >= minElements)
        {
            // can just move data
            if(valid > 0)
                copy(buffer[start..end], buffer[0..valid]);
        }
        else
        {
            auto oldLen = buffer.length;
            // grow by at least 1.4
            auto newLen = max(valid + minElements, oldLen * 14 / 10);
            static if(hasMember!(Allocator, "goodAllocSize"))
                newLen = theAllocator.goodAllocSize(newLen * T.sizeof) / T.sizeof;
            auto newbuf = cast(T[])theAllocator.allocate(newLen * T.sizeof);
            if (valid > 0) {
                // n + pageMask -> at least 1 page, no less then n
                copy(buffer[start .. end], newbuf[0 .. valid]);
            }
            // TODO: should we do this? using a GC allocator this is unsafe.
            static if(hasMember!(Allocator, "deallocate"))
                theAllocator.deallocate(buffer);
            buffer = newbuf;
        }
        
        return buffer.length - valid;
    }

private:
    Allocator theAllocator;
    T[] buffer;
}
