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
    @safe:
    import std.experimental.allocator.gc_allocator : GCAllocator;
    enum alignment = GCAllocator.alignment;

    /// Allocate some data
    static void[] allocate(size_t size) @trusted
    {
        import core.memory : GC;
        auto p = GC.malloc(size, GC.BlkAttr.NO_SCAN);
        return p ? (() @trusted => p[0 .. size])() : null;
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

@safe unittest
{
    import std.experimental.allocator.common: stateSize;
    static assert(!stateSize!GCNoPointerAllocator);
    import core.memory: GC;
    auto arr = GCNoPointerAllocator.instance.allocate(100);
    @trusted static noScan(void *ptr)
    {
        return (GC.getAttr(ptr) & GC.BlkAttr.NO_SCAN) != 0;
    }
    assert(noScan(&arr[0]));

    // not much reason to test of it, as it's just a wrapper for GCAllocator.
}

/**
 * Array based buffer manager. Uses custom allocator to get the data. Limits
 * growth to doubling.
 *
 * Params:
 *    T = The type of the elements the buffer will use
 *    Allocator = The allocator to use for adding more elements
 *    floorSize = The size that can be freely allocated before growth is restricted to 2x.
 *
 * Based on concept by Dmitry Olshansky
 */
struct AllocatedBuffer(T, Allocator = GCNoPointerAllocator, size_t floorSize = 8192)
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
    T[] window() @trusted
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

        if(buffer.length - validElems >= request)
        {
            // buffer has enough space if we move the data to the front.
            copy(buffer[released .. valid], buffer[0 .. validElems]);
            released = 0;
            valid = validElems + request;
            return request;
        }

        // otherwise, we must allocate/extend a new buffer
        // limit growth to 2x.
        immutable maxBufSize = max(buffer.length * 2, INITIAL_LENGTH);
        static if(hasMember!(Allocator, "expand"))
        {
            // try expanding, no further copying required
            if(buffer.ptr)
            {
                void[] buftmp = buffer;
                auto reqSize = min(maxBufSize - buffer.length,  request - (buffer.length - valid));
                if(allocator.expand(buftmp, reqSize * T.sizeof))
                {
                    auto newElems = buffer.length - valid + reqSize;
                    valid += newElems;
                    buffer = (()@trusted => cast(T[])buftmp)();
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

        static if(hasMember!(Allocator, "reallocate"))
        {
            if(released == 0 && validElems > 0)
            {
                // try using allocator's reallocate member
                void[] buf = buffer;
                if(allocator.reallocate(buf, newLen * T.sizeof))
                {
                    buffer = (()@trusted => cast(T[])buf)();
                    valid += request;
                    return request;
                }
            }
        }
        auto newbuf = (()@trusted => cast(T[])allocator.allocate(newLen * T.sizeof))();
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

@safe unittest
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
    auto buf = AllocatedBuffer!(ubyte, OOMAllocator)(OOMAllocator(arr));
    assert(buf.extend(100) == 100);
    assert(buf.avail == 28);
    assert(buf.capacity == 128);
    assert(buf.window.ptr == arr.ptr);

    buf.releaseFront(50);
    assert(buf.avail == 78);
    assert(buf.capacity == 128);
    assert(&buf.window[0] == &arr[50]);

    assert(buf.extend(50) == 50);
    assert(buf.capacity == 128);
    assert(&buf.window[0] == &arr[0]);

    assert(buf.extend(500) == 0);
    assert(buf.capacity == 128);
    assert(&buf.window[0] == &arr[0]);

    assert(buf.extend(100) == 100);
    assert(&buf.window[0] == &arr[128]);
    assert(buf.avail == 0);
    assert(buf.capacity == 200);
}

// The type allocated MUST be a power of 2
import std.math : isPowerOf2;

/**
 * A RingBuffer uses the underlying memory management system to avoid any
 * copying of data (unless expanding).
 *
 * It works by using the OS's mechanisms that map memory (mmap or VirtualAlloc)
 * to map the same region to 2 consecutive addresses. This allows one to use a
 * buffer simply as an array, even when the data wraps around the end of the
 * buffer.
 *
 * Like AllocatedBuffer, the growth is limited to doubling, but this has an
 * extra restriction that the buffer must be a multiple of the page size. Note
 * that this does NOT add any memory to the GC, so do not store GC pointers in
 * this buffer.
 *
 * Unlike AllocatedBuffer, this buffer is NOT copyable, so it must be
 * refcounted if you are to pass it around. See rbufd which does this
 * automatically for you. The reason for this is that it must unmap the memory
 * on destruction.
 *
 * Note that this buffer is not @safe, since it is possible on reallocation to
 * have dangling pointers (if anything keeps a reference to the original
 * memory).
 *
 * Params:
 *    T = The type of the elements the buffer will use. Must be sized as a power of 2.
 *    floorSize = The size that can be freely allocated before growth is
 *      restricted to 2x. Note that the OS imposes a floor size of one page in
 *      addition to this.
 */
struct RingBuffer(T, size_t floorSize = 8192) if (isPowerOf2(T.sizeof))
{
    @disable this(this); // we can't copy RingBuffer because otherwise it will deallocate the memory
    /**
     * Give bytes back to the buffer from the front of the buffer.
     * These bytes can be removed in this operation or further operations and
     * should no longer be used.
     *
     * Params: elements = number of elements to release.
     */
    void releaseFront(size_t elements)
    {
        assert(released + elements <= valid);
        released += elements;
        auto half = buffer.length / 2;
        if(released >= half)
        {
            released -= half;
            valid -= half;
        }
    }

    /**
     * Give bytes back to the buffer from the back of the buffer.
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
     * The window of currently valid data.
     */
    T[] window() @system
    {
        assert(released <= buffer.length && valid <= buffer.length);
        return buffer.ptr[released .. valid];
    }

    /**
     * Returns: The number of unused elements that can be extended without
     * needing to reallocate the buffer.
     */
    size_t avail()
    {
        return buffer.length / 2 - (valid - released);
    }

    /**
     * Returns: The total number of elements currently managed.
     */
    size_t capacity()
    {
        return buffer.length / 2;
    }

    /**
     * Add more data to the window of currently valid data. To avoid expensive
     * reallocation, use avail to tune this call.
     *
     * Params: request = The number of additional elements to add to the valid window.
     * Returns: The number of elements that were actually added to the valid
     * window. Note that this may be less than the request if more elements
     * could not be attained from the OS.
     */
    size_t extend(size_t request) @system
    {
        import std.algorithm.mutation : copy;
        import std.algorithm.comparison : max, min;
        import core.sys.posix.unistd;
        version (Posix) import core.sys.posix.sys.mman;
        version (FreeBSD) import core.sys.freebsd.sys.mman : MAP_FIXED, MAP_SHARED, MAP_ANON;
        version (NetBSD) import core.sys.netbsd.sys.mman : MAP_FIXED, MAP_SHARED, MAP_ANON;
        version (linux) import core.sys.linux.sys.mman : MAP_FIXED, MAP_SHARED, MAP_ANON;
        version (OSX) import core.sys.darwin.sys.mman : MAP_FIXED, MAP_SHARED, MAP_ANON;
        import core.sys.posix.fcntl;


        // check to see if we can "move" the data for free.
        auto validElems = valid - released;
        if(validElems == 0)
            valid = released = 0;

        // we should never have to move data
        immutable cap = buffer.length / 2;
        assert(valid + cap - released <= buffer.length);
        if(cap - validElems >= request)
        {
            // buffer has enough free space to accomodate.
            valid += request;
            return request;
        }

        // otherwise, we must allocate/extend a new buffer
        // limit growth to 2x.
        immutable maxBufSize = max(cap * 2, floorSize);

        // copy and allocate a new buffer
        auto oldLen = buffer.length;
        // grow by at least 1.4, but not more than maxBufSize
        request = min(request, maxBufSize - validElems);
        auto fullSize = max(validElems + request, oldLen * 14 / 10, floorSize) * T.sizeof;
        // round up to PAGESIZE
        fullSize = (fullSize + PAGESIZE - 1) / PAGESIZE * PAGESIZE;

        // mmap space to reserve the address space. We won't actually wire this
        // to any memory until we open the shared memory and map it.
        auto addr = mmap(null, fullSize * 2, PROT_NONE, MAP_SHARED | MAP_ANON, -1, 0);
        if(addr == MAP_FAILED)
            return 0;

        // attempt to make a name that won't conflict with other processes.
        // This is really sucky, but is required on posix systems, even though
        // we aren't really sharing memory.
        enum basename = "/iopipe_map_";
        char[basename.length + 8 + 1] shm_name = void;
        shm_name[0 .. basename.length] = basename;
        shm_name[basename.length .. $-1] = 'A';
        // get the process id
        import std.process: thisProcessID;
        uint pid = thisProcessID();
        auto idx = basename.length;
        while(pid)
        {
            shm_name[idx++] = cast(char)('A' + (pid & 0x0f));
            pid >>= 4;
        }
        shm_name[$-1] = 0;

        import std.conv: octal;
        import std.exception;
        int shfd = -1;
        idx = 0;
        while(shfd < 0)
        {
            // try 4 times to make this happen, if it doesn't, give up and
            // return 0. This helps solve any possible race conditions with
            // other threads. It's not perfect, but it should work reasonably
            // well.
            if(idx++ > 4)
            {
                munmap(addr, fullSize * 2);
                return 0;
            }
            shfd = shm_open(shm_name.ptr, O_RDWR | O_CREAT | O_EXCL, octal!"600");
            // immediately remove the name link, we don't really want to share anything here.
            shm_unlink(shm_name.ptr);
        }

        // after this function, we don't need the file descriptor.
        scope(exit) close(shfd);

        // create enough memory to hold the entire buffer.
        if(ftruncate(shfd, fullSize) < 0)
        {
            munmap(addr, fullSize * 2);
            return 0;
        }

        // map the shared memory into the reserved space twice, each half sees
        // the same memory.
        if(mmap(addr, fullSize, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, shfd, 0) == MAP_FAILED)
        {
            munmap(addr, fullSize * 2);
            return 0;
        }
        if(mmap(addr + fullSize, fullSize, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, shfd, 0) == MAP_FAILED)
        {
            munmap(addr, fullSize * 2);
            return 0;
        }
        auto newbuf = cast(T[])(addr[0 .. fullSize * 2]);
        if (validElems > 0) {
            copy(buffer[released .. valid], newbuf[0 .. validElems]);
        }
        valid = validElems + request;
        assert(valid <= newbuf.length / 2);
        released = 0;
        // UNSAFE -- only use this in system code
        if(buffer.length)
            munmap(buffer.ptr, buffer.length * T.sizeof); // unmap the original memory
        buffer = newbuf;

        return request;
    }

    ~this() @system
    {
        if(buffer.ptr)
        {
            version (Posix)
            {
                import core.sys.posix.sys.mman;
                munmap(buffer.ptr, buffer.length * T.sizeof);
            }
        }
    }

private:
    // Note: the buffer is 2 mmaps to the same memory page.
    T[] buffer;
    // We will only ever use 1/2 of the buffer at the most, 
    size_t valid;
    size_t released;
}

@system unittest
{
    RingBuffer!(ubyte, 8192) buf;
    assert(buf.extend(4096) == 4096);
    // some systems do not have a page size of 4k
    auto cap = buf.capacity;
    assert(cap >= 8192);
    assert(buf.avail == cap - 4096);
    buf.window[0] = 0;
    assert(buf.buffer.length == cap * 2);

    assert(buf.extend(4096) == 4096);
    assert(buf.avail == cap - 8192);
    assert(buf.capacity == cap);

    buf.releaseFront(4096);
    assert(buf.avail == cap - 4096);
    assert(buf.capacity == cap);
    assert(buf.extend(4096) == 4096);
    assert(buf.avail == cap - 8192);
    assert(buf.capacity == cap);
    import std.algorithm : copy, map, equal;
    import std.range : iota;
    iota(8192).map!(a => cast(ubyte)a).copy(buf.window);
    assert(equal(iota(8192).map!(a => cast(ubyte)a), buf.window));
    buf.releaseFront(4096);
    assert(equal(iota(4096, 8192).map!(a => cast(ubyte)a), buf.window));
    assert(buf.released <= cap); // assure we wrap around
    assert(buf.extend(8192) == 8192);
    assert(equal(iota(4096, 8192).map!(a => cast(ubyte)a), buf.window[0 .. 4096]));
}

package static immutable size_t PAGESIZE;

// unfortunately, this is the only way to do it for now. Copied from
// core.thread
shared static this()
{
    version (Windows)
    {
        import core.sys.windows.windows;
        SYSTEM_INFO info;
        GetSystemInfo(&info);

        PAGESIZE = info.dwPageSize;
        assert(PAGESIZE < int.max);
    }
    else version (Posix)
    {
        import core.sys.posix.unistd;
        PAGESIZE = cast(size_t)sysconf(_SC_PAGESIZE);
    }
    else
    {
        static assert(0, "unimplemented");
    }
}
