/**
 Buffer handling for iopipe.

Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy
           at http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer, Dmitry Olshansky
 */
module iopipe.buffer;
import std.experimental.allocator : IAllocator;
import std.experimental.allocator.common : platformAlignment;

/**
 * GC allocator that creates blocks of non-pointer data (unscanned). This also
 * does not support freeing data, relying on the GC to do so.
 */
struct GCNoPointerAllocator
{
    import std.experimental.allocator.gc_allocator : GCAllocator;
    enum alignment = GCAllocator.alignment;

    /// Allocate some data
    static void[] allocate(size_t size)
    {
        import core.memory : GC;
        auto p = GC.malloc(size, GC.BlkAttr.NO_SCAN);
        return p ? p[0 .. size] : null;
    }

    /// Determine an appropriate size for allocation to hold the given size data
    static size_t goodAllocSize(size_t size)
    {
        // mimic GCAllocator
        return GCAllocator.instance.goodAllocSize(size);
    }

    /// Expand some data
    static bool expand(ref void[] original, size_t size)
    {
        // mimic GCAllocator
        return GCAllocator.instance.expand(original, size);
    }

    /// The shared instance
    static shared GCNoPointerAllocator instance;
}

unittest
{
    import std.experimental.allocator.common: stateSize;
    static assert(!stateSize!GCNoPointerAllocator);
    import core.memory: GC;
    auto arr = GCNoPointerAllocator.instance.allocate(100);
    assert((GC.getAttr(arr.ptr) & GC.BlkAttr.NO_SCAN) != 0);

    // not much reason to test of it, as it's just a wrapper for GCAllocator.
}

/**
 * Array based buffer manager. Uses custom allocator to get the data. Limits
 * growth to doubling.
 *
 * Params:
 *    T = The type of the elements the buffer manager will use
 *    Allocator = The allocator to use for adding more elements
 *    floorSize = The size that can be freely allocated before growth is restricted to 2x.
 *
 * Based on concept by Dmitry Olshansky
 */
struct BufferManager(T, Allocator = GCNoPointerAllocator, size_t floorSize = 8192)
{
    import std.experimental.allocator.common: stateSize;
    import std.experimental.allocator: IAllocator, theAllocator;

    /**
     * Construct a buffer manager with a given allocator.
     */
    static if (stateSize!Allocator)
    {
        private Allocator _allocator;
        static if (is(Allocator == IAllocator))
        {
            private @property Allocator allocator()
            {
                if (_allocator is null) _allocator = theAllocator;
                return _allocator;
            }
        }
        else
        {
            private alias allocator = _allocator;
        }
        this(Allocator alloc) {
            _allocator = alloc;
        }
    }
    else // no state size
    {
        private alias allocator = Allocator.instance;
    }

    /**
     * Give bytes back to the buffer manager from the front of the buffer.
     * These bytes can be removed in this operation or further operations and
     * should no longer be used.
     *
     * Params: elements = number of elements to release.
     */
    void releaseFront(size_t elements)
    {
        assert(released + elements <= valid);
        released += elements;
    }

    /**
     * Give bytes back to the buffer manager from the back of the buffer.
     * These bytes can be removed in this operation or further operations and
     * should no longer be used.
     *
     * Params: elements = number of elements to release.
     */
    void releaseBack(size_t elements)
    {
        assert(released + elements <= valid);
        valid -= elements;
    }

    /**
     * The window of currently valid data
     */
    T[] window()
    {
        return buffer.ptr[released .. valid];
    }

    /**
     * Returns: The number of unused elements that can be extended without
     * needing to fetch more data from the allocator.
     */
    size_t avail()
    {
        return buffer.length - (valid - released);
    }

    /**
     * Returns: The total number of elements currently managed.
     */
    size_t capacity()
    {
        return buffer.length;
    }

    /**
     * Add more data to the window of currently valid data. To avoid expensive
     * reallocation, use avail to tune this call.
     *
     * Params: request = The number of additional elements to add to the valid window.
     * Returns: The number of elements that were actually added to the valid
     * window. Note that this may be less than the request if more elements
     * could not be attained from the allocator.
     */
    size_t extend(size_t request)
    {
        import std.algorithm.mutation : copy;
        import std.algorithm.comparison : max, min;
        import std.traits : hasMember;

        // check to see if we can "move" the data for free.
        auto validElems = valid - released;
        if(validElems == 0)
            valid = released = 0;

        if(buffer.length - valid >= request)
        {
            // buffer has enough free space to accomodate.
            valid += request;
            return request;
        }

        if(validElems + request <= buffer.length)
        {
            // buffer has enough space if we move the data to the front.
            copy(buffer[released .. valid], buffer[0 .. validElems]);
            released = 0;
            valid = validElems + request;
            return request;
        }

        // otherwise, we must allocate/extend a new buffer
        // limit growth to 2x.
        immutable maxBufSize = max(buffer.length * 2, floorSize);
        static if(hasMember!(Allocator, "expand"))
        {
            // try expanding, no further copying required
            if(buffer.ptr)
            {
                void[] buftmp = cast(void[])buffer;
                auto reqSize = min(maxBufSize - buffer.length,  request - (buffer.length - valid));
                if(allocator.expand(buftmp, reqSize * T.sizeof))
                {
                    auto newElems = buffer.length - valid + reqSize;
                    valid += newElems;
                    buffer = cast(T[])buftmp;
                    return newElems;
                }
            }
        }

        // copy and allocate a new buffer
        auto oldLen = buffer.length;
        // grow by at least 1.4, but not more than maxBufSize
        request = min(request, maxBufSize - validElems);
        auto newLen = max(validElems + request, oldLen * 14 / 10, INITIAL_LENGTH);
        static if(hasMember!(Allocator, "goodAllocSize"))
            newLen = allocator.goodAllocSize(newLen * T.sizeof) / T.sizeof;
        auto newbuf = cast(T[])allocator.allocate(newLen * T.sizeof);
        if(!newbuf.ptr)
            return 0;
        if (validElems > 0) {
            copy(buffer[released .. valid], newbuf[0 .. validElems]);
        }
        valid = validElems + request;
        released = 0;

        // TODO: should we do this? using a GC allocator this is unsafe.
        static if(hasMember!(Allocator, "deallocate"))
            allocator.deallocate(buffer);
        buffer = newbuf;

        return request;
    }
private:
    enum size_t INITIAL_LENGTH = (128 < floorSize ? 128 : floorSize);
    T[] buffer;
    size_t valid;
    size_t released;
}

unittest
{
    static struct OOMAllocator
    {
        void[] remaining;
        enum alignment = 1;
        void[] allocate(size_t bytes)
        {
            if(remaining.length >= bytes)
            {
                scope(exit) remaining = remaining[bytes .. $];
                return remaining[0 .. bytes];
            }
            return null;
        }
    }

    auto arr = new void[128 + 200];
    auto buf = BufferManager!(ubyte, OOMAllocator)(OOMAllocator(arr));
    assert(buf.extend(100) == 100);
    assert(buf.avail == 28);
    assert(buf.capacity == 128);
    assert(buf.window.ptr == arr.ptr);

    buf.releaseFront(50);
    assert(buf.avail == 78);
    assert(buf.capacity == 128);
    assert(buf.window.ptr == arr.ptr + 50);

    assert(buf.extend(50) == 50);
    assert(buf.capacity == 128);
    assert(buf.window.ptr == arr.ptr);

    assert(buf.extend(500) == 0);
    assert(buf.capacity == 128);
    assert(buf.window.ptr == arr.ptr);

    assert(buf.extend(100) == 100);
    assert(buf.window.ptr == arr.ptr + 128);
    assert(buf.avail == 0);
    assert(buf.capacity == 200);
}
