/**
Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy at
           http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer, Dmitry Olshansky
 */
module iopipe.buffer;
import std.experimental.allocator : IAllocator;
import std.experimental.allocator.common : platformAlignment;

struct GCNoPointerAllocator
{
    enum alignment = platformAlignment;

    /// Allocate some data
    void[] allocate(size_t size) pure nothrow
    {
        import core.memory : GC;
        auto blkinfo = GC.qalloc(size, GC.BlkAttr.NO_SCAN);
        return blkinfo.base[0 .. blkinfo.size];
    }

    /// Expand some data
    bool expand(ref void[] original, size_t size) pure nothrow
    {
        import core.memory : GC;
        if(!original.ptr)
        {
            original = allocate(size);
            return original.ptr != null;
        }

        auto nBytes = GC.extend(original.ptr, size, size);
        if(nBytes == 0)
            return false;
        original = original.ptr[0 .. nBytes];
        return true;
    }
}

/**
 * Array-based buffer
 *
 * Based on concept by Dmitry Olshansky
 */
struct BufferManager(T, Allocator = GCNoPointerAllocator)
{
    this(Allocator allocator) {
        theAllocator = allocator;
    }

    // give bytes back to the buffer manager at the front
    void releaseFront(size_t elements)
    {
        assert(released + elements <= valid);
        released += elements;
    }

    // give bytes back to the buffer manager at the back.
    void releaseBack(size_t elements)
    {
        assert(released + elements <= valid);
        valid -= elements;
    }

    // get the current window of data
    T[] window()
    {
        return buffer.ptr[released .. valid];
    }

    // get the number of available elements that could be extended without reallocating.
    size_t avail()
    {
        return buffer.length - (valid - released);
    }

    size_t capacity()
    {
        return buffer.length;
    }

    size_t extend(size_t request)
    {
        import std.algorithm.mutation : copy;
        import std.algorithm.comparison : max;
        import std.traits : hasMember;
        if(buffer.length - valid >= request)
        {
            valid += request;
            return request;
        }

        auto validElems = valid - released;
        if(validElems + request <= buffer.length)
        {
            // can just move the data
            copy(buffer[released .. valid], buffer[0 .. validElems]);
            released = 0;
            valid = validElems + request;
            return request;
        }

        // otherwise, we must allocate/extend a new buffer

        static if(hasMember!(Allocator, "expand"))
        {
            // try expanding, no further copying required
            if(buffer.ptr)
            {
                void[] buftmp = cast(void[])buffer;
                if(theAllocator.expand(buftmp, (request - (buffer.length - valid)) * T.sizeof))
                {
                    buffer = cast(T[])buftmp;
                    if(validElems == 0)
                    {
                        valid = request;
                        released = 0;
                    }
                    else
                    {
                        valid += request;
                    }
                    return request;
                }
            }
        }

        // copy and allocate a new buffer
        auto oldLen = buffer.length;
        if(oldLen == 0)
            // need to start somewhere
            oldLen = INITIAL_LENGTH;
        // grow by at least 1.4
        auto newLen = max(validElems + request, oldLen * 14 / 10);
        static if(hasMember!(Allocator, "goodAllocSize"))
            newLen = theAllocator.goodAllocSize(newLen * T.sizeof) / T.sizeof;
        auto newbuf = cast(T[])theAllocator.allocate(newLen * T.sizeof);
        if(!newbuf.ptr)
            return 0;
        if (validElems > 0) {
            // n + pageMask -> at least 1 page, no less then n
            copy(buffer[released .. valid], newbuf[0 .. validElems]);
        }
        valid = validElems + request;
        released = 0;

        // TODO: should we do this? using a GC allocator this is unsafe.
        static if(hasMember!(Allocator, "deallocate"))
            theAllocator.deallocate(buffer);
        buffer = newbuf;

        return request;
    }
private:
    Allocator theAllocator;
    enum size_t INITIAL_LENGTH = 128;
    T[] buffer;
    size_t valid;
    size_t released;
}
