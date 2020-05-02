/**
  Core functionality for iopipe. Defines the base types for manipulating and
  processing data.
Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy
           at http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.bufpipe;
import iopipe.buffer;
import iopipe.traits;
import std.traits : isDynamicArray, hasMember;
import std.range.primitives;


/**
 * An example processor. This demonstrates the required items for implementing
 * an iopipe.
 *
 * SimplePipe will only extend exactly the elements requested (from what is
 * availble), so it can be used for testing with a static buffer to simulate
 * data coming in at any rate.
 */
struct SimplePipe(Chain, size_t extendElementsDefault = 1) if(isIopipe!Chain)
{
    /**
     * The upstream data. This can be any iopipe. Throughout the library, the
     * upstream data is generally saved as a member called "chain" as a matter
     * of convention. This is not required or expected.
     */
    Chain chain;

    // how many elements are we looking at.
    private size_t downstreamElements;

    /**
     * Build on top of an existing chain 
     */
    this(Chain c)
    {
        this.chain = c;
    }

    /**
     * Get the current window of elements for the pipe. This is the data that
     * can be used at this moment in time.
     */
    auto window() { return chain.window[0..downstreamElements]; }

    /**
     * Get more data from the pipe. The parameter indicates the desired number
     * of elements to add to the end of the window. If 0 is passed, then it is
     * up to the implementation of the pipe to determine the optimal number of
     * elements to add.
     *
     * Params: elements = Number of elements requested.
     * Returns: The number of elements added. This can be less than or more
     *          than the parameter, but will only be 0 when no more elements
     *          can be added. This signifies EOF.
     */
    size_t extend(size_t elements)
    {
        auto left = chain.window.length - downstreamElements;
        if(elements == 0)
        {
            elements = extendElementsDefault;
            // special case
            if(elements <= left)
            {
                downstreamElements += elements;
                return elements;
            }
            else
            {
                elements = chain.extend(0);
                downstreamElements += left + elements;
                return left + elements;
            }
        }
        else if(elements <= left)
        {
            downstreamElements += elements;
            return elements;
        }
        else
        {
            elements -= left;
            left += chain.extend(elements);
            downstreamElements += left;
            return left;
        }
    }

    /**
     * Release the given number of elements from the front of the window. After
     * calling this, make sure to update any tracking indexes for the window
     * that you are maintaining.
     *
     * Params: elements = The number of elements to release.
     */
    void release(size_t elements)
    {
        assert(elements <= downstreamElements);
        downstreamElements -= elements;
        chain.release(elements);
    }

    static if(hasValve!(Chain))
    {
        /**
         * Implement the required valve function. If the pipe you are wrapping
         * has a valve, you must provide ref access to the valve.
         *
         * Note, the correct boilerplate implementation can be inserted by
         * adding the following line to your pipe structure:
         *
         * ------
         * mixin implementValve!(nameOfUpstreamPipe);
         * ------
         *
         * Returns: A valve inlet that allows you to control flow of the data
         * through this pipe.
         *
         * See Also: iopipe.valve
         */
        ref valve() { return chain.valve; }
    }
}

///
@safe unittest
{
    // any array is a valid iopipe source.
    auto source = "hello, world!";

    auto pipe = SimplePipe!(string)(source);

    // SimplePipe holds back data until you extend it.
    assert(pipe.window.length == 0);

    // Note: elements of narrow strings are code units for purposes of iopipe
    // library.
    assert(pipe.extend(5) == 5);
    assert(pipe.window == "hello");

    // Release data to inform the pipe you are done with it
    pipe.release(3);
    assert(pipe.window == "lo");

    // you can request "some data" by extending with 0, letting the pipe define
    // what is the best addition of data. This is useful for optimizing OS
    // system call reads.
    assert(pipe.extend(0) == 1);
    assert(pipe.window == "lo,");

    // you aren't guaranteed to get all the data you ask for.
    assert(pipe.extend(100) == 7);
    assert(pipe.window == "lo, world!");

    pipe.release(pipe.window.length);

    // this signifies EOF.
    assert(pipe.extend(1) == 0);
}

@safe unittest
{
    import std.range : iota, array;
    import std.algorithm : equal;
    auto buf = iota(100).array;
    auto p = SimplePipe!(typeof(buf))(buf);

    assert(p.window.length == 0);
    assert(p.extend(50) == 50);
    assert(p.window.length == 50);
    assert(p.window.equal(iota(50)));
    p.release(20);
    assert(p.window.length == 30);
    assert(p.window.equal(iota(20, 50)));
    assert(p.extend(100) == 50);
    assert(p.window.length == 80);
    assert(p.window.equal(iota(20, 100)));
    p.release(80);
    assert(p.extend(1) == 0);
    assert(p.window.length == 0);
}

private void swapBytes(R)(R data) if(typeof(R.init[0]).sizeof == 4 || typeof(R.init[0]).sizeof == 2)
{
    enum width = typeof(R.init[0]).sizeof;
    if(data.length == 0)
        // no reason to byteswap no data
        return;
    static if(width == 2)
    {
        // TODO: this only works for arrays.
        ushort[] sdata = cast(ushort[])data;
        () @trusted {
            assert(sdata.length > 0);
            if((cast(size_t)sdata.ptr & 0x03) != 0)
            {
                // first element not 4-byte aligned, do that one by hand
                *sdata.ptr = ((*sdata.ptr << 8) & 0xff00) |
                    ((*sdata.ptr >> 8) & 0x00ff);
                sdata.popFront();
            }

            // handle misaligned last element
            if(sdata.length % 2 != 0)
            {
                const last = sdata.length - 1;
                sdata.ptr[last] = ((sdata.ptr[last] << 8) & 0xff00) |
                    ((sdata.ptr[last] >> 8) & 0x00ff);
                sdata.popBack();
            }
        }();

        // rest of the data is 4-byte multiple and aligned
        // TODO:  see if this can be optimized further, or if there are
        // better options for 64-bit.
        uint[] idata = cast(uint[])sdata;
        foreach(ref t; idata)
        {
            t = ((t << 8) & 0xff00ff00) |
                ((t >> 8) & 0x00ff00ff);
        }
    }
    else
    {
        import core.bitop : bswap;
        // swap every 4 bytes
        foreach(ref t; cast(uint[])data)
        {
            t = bswap(t);
        }
    }
}

@safe unittest
{
    void doIt(T)(T[] t) @safe
    {
        import std.algorithm;
        import std.range;
        auto compareTo = t.map!(a => (a << ((T.sizeof-1) * 8))).array;
        swapBytes(t);
        assert(t == compareTo);
    }

    doIt(cast(ushort[])[1, 2, 3, 4, 5]);
    doIt(cast(uint[])[6, 7, 8, 9, 10]);
}

// should be a voldemort type, but that results in template bloat
private struct ByteSwapProcessor(Chain)
{
    Chain chain;

    auto window() { return chain.window; }
    size_t extend(size_t elements)
    {
        auto newData = chain.extend(elements);
        auto data = chain.window;
        swapBytes(data[$-newData..$]);
        return newData;
    }

    void release(size_t elements) { chain.release(elements); }

    mixin implementValve!(chain);
}

version(LittleEndian)
    private enum IsLittleEndian = true;
else
    private enum IsLittleEndian = false;

/**
 * Swap the bytes of every element before handing to next processor. The
 * littleEndian compile-time parameter indicates what endianness the data is
 * in. If it matches the platform's endianness, then nothing is done (no byte
 * swap occurs). Otherwise, a byte swap processor is returned wrapping the io
 * pipe.
 *
 * Note, the width of the elements in the iopipe's window must be 2 or 4 bytes
 * wide, and mutable.
 *
 * Params: littleEndian = true if the data arrives in little endian mode, false
 *             if in big endian mode.
 *         c = Source pipe chain for the byte swapper.
 * Returns: If endianness of the source matches platform, this returns c,
 *          otherwise, it returns a byte swapping iopipe wrapper that performs
 *          the byte swaps.
 */
auto byteSwapper(bool littleEndian = !IsLittleEndian, Chain)(Chain c) if(isIopipe!(Chain) && is(typeof(swapBytes(c.window))))
{
    version(LittleEndian)
    {
        static if(littleEndian)
            return c;
        else
        {
            swapBytes(c.window);
            return ByteSwapProcessor!Chain(c); 
        }
    }
    else
    {
        static if(littleEndian)
        {
            // need to byteswap existing data, since we only byteswap on extend
            swapBytes(c.window);
            return ByteSwapProcessor!Chain(c);
        }
        else
            return c;
    }
}

@safe unittest
{
    import std.algorithm;
    auto arr = [1, 2, 3, 4, 5];
    auto c = arr.dup.byteSwapper;
    assert(c.window.equal(arr.map!(a => (a << 24))));
}

private struct ArrayCastPipe(Chain, T) if(isIopipe!(Chain) && isDynamicArray!(WindowType!(Chain)))
{
    Chain chain;
    // upstream element type
    alias UE = typeof(Chain.init.window()[0]);

    static if(UE.sizeof > T.sizeof)
    {
        // needed to keep track of partially released elements.
        ubyte offset;
        enum Ratio = UE.sizeof / T.sizeof;
        static assert(UE.sizeof % T.sizeof == 0); // only support multiples
    }
    else
    {
        enum Ratio = T.sizeof / UE.sizeof;
        static assert(T.sizeof % UE.sizeof == 0);
    }

    auto window() @trusted
    {
        static if(UE.sizeof > T.sizeof)
        {
            // note, we avoid a cast of arrays because that invokes a runtime call
            auto w = chain.window;
            return (cast(T*)w.ptr)[offset .. w.length * Ratio];
        }
        else static if(UE.sizeof == T.sizeof)
            // ok to cast array here, because it's the same size (no runtime call)
            return cast(T[])chain.window;
        else
        {
            // note, we avoid a cast of arrays because that invokes a runtime call
            auto w = chain.window;
            return (cast(T*)w.ptr)[0 .. w.length / Ratio];
        }
    }

    size_t extend(size_t elements)
    {
        static if(UE.sizeof < T.sizeof)
        {
            // need a minimum number of items
            auto win = chain.window;
            immutable origLength = win.length / Ratio;
            auto targetLength = win.length + Ratio - win.length % Ratio;
            while(win.length < targetLength)
            {
                if(chain.extend(elements * Ratio) == 0)
                {
                    return 0;
                }
                win = chain.window;
            }
            return window.length - origLength;
        }
        else
        {
            // need to round up to the next UE.
            immutable translatedElements = (elements + Ratio - 1) / Ratio;
            return chain.extend(translatedElements) * Ratio;
        }
    }

    void release(size_t elements)
    {
        static if(UE.sizeof <= T.sizeof)
        {
            chain.release(elements * Ratio);
        }
        else
        {
            // may need to keep one of the upstream elements because we only
            // released part of it
            elements += offset;
            offset = elements % Ratio;
            chain.release(elements / Ratio);
        }
    }

    mixin implementValve!(chain);
}

/**
 * Given a pipe chain whose window is a straight array, create a pipe chain that
 * converts the array to another array type.
 *
 * Note: This new pipe chain handles any alignment issues when partial
 *       elements have been extended/released. Also, the size of the new
 *       element type must be a multiple of, or divide evenly into, the
 *       original array.
 *
 * Params: T = Element type for new pipe chain window
 *         c = Source pipe chain to use for new chain.
 *
 * Returns: New pipe chain with new array type.
 */
auto arrayCastPipe(T, Chain)(Chain c) @safe if(isIopipe!(Chain) && isDynamicArray!(WindowType!(Chain)))
{
    static if(is(typeof(c.window[0]) == T))
        return c;
    else
        return ArrayCastPipe!(Chain, T)(c);
}

@safe unittest
{
    // test going from int to ubyte
    auto arr = [1, 2, 3, 4, 5];
    auto arr2 = cast(ubyte[])arr;
    auto p = arr.arrayCastPipe!(ubyte);
    assert(p.window == arr2);
    p.release(3);
    assert(p.window == arr2[3 .. $]);
    // we can only release when all 4 bytes of the array are gone
    assert(p.chain == arr);
    p.release(1);
    assert(p.chain == arr[1 .. $]);

    // test going from ubyte to int, but shave off one byte
    assert(arr2[0 .. $-1].arrayCastPipe!(int).window == arr[0 .. $-1]);
}

/**
 * Extend a pipe until it has a minimum number of elements. If the minimum
 * elements are already present, does nothing.
 *
 * This is useful if you need a certain number of elements in the pipe before
 * you can process any more data.
 *
 * Params: chain = The pipe to work on.
 *         elems = The number of elements to ensure are in the window. If
 *         omitted, all elements are extended.
 * Returns: The resulting number of elements in the window. This may be less
 *          than the requested elements if the pipe ran out of data.
 */
size_t ensureElems(Chain)(ref Chain chain, size_t elems = size_t.max)
{
    while(chain.window.length < elems)
    {
        if(chain.extend(elems - chain.window.length) == 0)
            break;
    }
    return chain.window.length;
}

@safe unittest
{
    auto p = SimplePipe!(string)("hello, world");
    assert(p.ensureElems(5) == 5);
    assert(p.window == "hello");
    assert(p.ensureElems(3) == 5);
    assert(p.window == "hello");
    assert(p.ensureElems(100) == 12);
    assert(p.window == "hello, world");
}

// bug #11
@safe unittest
{
    auto x = "hello, world".iosrc!((ref c, b) {
                                   if(b.length > c.window.length)
                                      b = b[0 .. c.window.length];
                                   b[] = c.window[0 .. b.length];
                                   c.release(b.length);
                                   return b.length; })
                                   .bufd!(char);
    auto elems = x.ensureElems();
    assert(elems == 12);
}

struct BufferedInputSource(BufferManager, Source, size_t optimalReadSize)
{
    Source dev;
    BufferManager buffer;
    auto window()
    {
        return buffer.window;
    }

    void release(size_t elements)
    {
        buffer.releaseFront(elements);
    }

    size_t extend(size_t elements)
    {
        import std.algorithm.comparison : max, min;
        auto oldLen = buffer.window.length;

        if(elements == 0 || (elements < optimalReadSize && buffer.capacity == 0))
        {
            // optimal read, or first read. Use optimal read size
            elements = optimalReadSize;
        }
        else
        {
            // requesting a specific amount. Don't want to over-allocate the
            // buffer, limit the request to 2x current elements, or optimal
            // read size, whatever is larger.
            immutable cap = max(optimalReadSize, oldLen * 2);
            if(elements > cap)
                elements = cap;
        }

        // ensure we maximize buffer use.
        elements = max(elements, buffer.avail());

        if(buffer.extend(elements) == 0)
        {
            // could not extend;
            return 0;
        }

        auto nread = dev.read(buffer.window[oldLen .. $]);
        // give back data we did not read.
        buffer.releaseBack(buffer.window.length - oldLen - nread);
        return nread;
    }

    // need to forward valves if we are going through rebuffered data.
    static if(hasValve!Source)
        mixin implementValve!dev;
}

/**
 * Create a buffer to manage the data from the given source, and wrap into an iopipe.
 *
 * Params: T = The type of element to allocate with the allocator
 *         Allocator = The allocator to use for managing the buffer
 *         Source = The type of the input stream. This must have a function
 *         `read` that can read into the buffer's window.
 *         dev = The input stream to use. If not specified, then a NullDev source is assumed.
 *         args = Arguments passed to the allocator (for allocators that need initialization)
 *
 * Returns: An iopipe that uses the given buffer to read data from the given device source.
 * The version which takes no parameter uses a NullDev as a source.
 */
auto bufd(T=ubyte, Allocator = GCNoPointerAllocator, size_t optimalReadSize = 8 * 1024 / T.sizeof, Source, Args...)(Source dev, Args args)
    if(hasMember!(Source, "read") && is(typeof(dev.read(T[].init)) == size_t))
{
    alias BM = AllocatedBuffer!(T, Allocator, optimalReadSize);
    static if(Args.length > 0)
        return BufferedInputSource!(BM, Source, optimalReadSize)(dev, BM(Allocator(args)));
    else
        return BufferedInputSource!(BM, Source, optimalReadSize)(dev);
}

/// ditto
auto bufd(T=ubyte, Allocator = GCNoPointerAllocator, size_t optimalReadSize = (T.sizeof > 4 ?  8 : 32 / T.sizeof), Args...)(Args args)
{
    import iopipe.stream: nullDev;
    return nullDev.bufd!(T, Allocator, optimalReadSize)(args);
}

/**
 * Create a ring buffer to manage the data from the given source, and wrap into an iopipe.
 *
 * The iopipe RingBuffer type uses virtual memory mapping to have the same
 * segment of data mapped to consecutive addresses. This allows true zero-copy
 * usage. However, it does require use of resources that may possibly be
 * limited, so you may want to justify that it's needed before using instead of
 * bufd.
 *
 * Note also that a RingBuffer is not copyable (its destructor will unmap the
 * memory), so this must use RefCounted to properly work.
 *
 * Params: T = The type of element to allocate with the allocator
 *         Source = The type of the input stream. This must have a function
 *         `read` that can read into the buffer's window.
 *         dev = The input stream to use. If not specified, then a NullDev source is assumed.
 *
 * Returns: An iopipe that uses a RingBuffer to read data from the given device source.
 */
auto rbufd(T=ubyte, size_t optimalReadSize = 8 * 1024 / T.sizeof, Source)(Source dev)
    if(hasMember!(Source, "read") && is(typeof(dev.read(T[].init)) == size_t))
{
    // need to refcount the ring buffer, since it's not copyable
    import std.typecons : refCounted;
    auto buffer = refCounted(RingBuffer!T());
    return BufferedInputSource!(typeof(buffer), Source, optimalReadSize)(dev, buffer);
}

/// Ditto
auto rbufd(T=ubyte, size_t optimalReadSize = 8 * 1024 / T.sizeof)()
{
    import iopipe.stream: nullDev;
    return nullDev.rbufd!(T, optimalReadSize)();
}

// allocate using a region buffer (convenience)
auto lbufd(T=ubyte, size_t optimalReadSize = 128, Source)(Source dev, ubyte[] buf)
{
    import std.experimental.allocator.building_blocks.region;
    // for now, we only support buffers at least large enough to hold the
    // initial read.
    assert(buf.length >= optimalReadSize);
    return bufd!(T, Region!(), optimalReadSize)(dev, buf);
}

// allocate using a region buffer (convenience)
auto lbufd(T=ubyte, size_t optimalReadSize = 128)(ubyte[] buf)
{
    import iopipe.stream : nullDev;
    return lbufd!(T, optimalReadSize)(nullDev, buf);
}

@safe unittest
{
    // simple struct that "reads" data from a pre-defined string array into a char buffer.
    static struct ArrayReader
    {
        string _src;
        size_t read(char[] data)
        {
            auto ntoread = data.length;
            if(ntoread > _src.length)
                ntoread = _src.length;
            data[0 .. ntoread] = _src[0 .. ntoread];
            _src = _src[ntoread .. $];
            return ntoread;
        }
    }

    void test(P)(P p)
    {
        assert(p.window.length == 0);
        assert(p.extend(0) == 13);
        assert(p.window == "hello, world!");
        assert(p.extend(0) == 0);
    }
    test(ArrayReader("hello, world!").bufd!char);
    // ring buffers are @system
    () @trusted { test(ArrayReader("hello, world!").rbufd!char); }();
}

private struct OutputPipe(Chain, Sink)
{
    Sink dev;
    Chain chain;

    auto window()
    {
        return chain.window();
    }

    size_t extend(size_t elements)
    {
        // get new elements, and then write them to the file
        auto newData = chain.extend(elements);
        ensureWritten(newData);
        return newData;
    }

    void release(size_t elements)
    {
        // just upstream this
        chain.release(elements);
    }

    size_t flush(size_t elements)
    {
        // extend and then release all data
        extend(elements);
        auto result = window.length;
        release(window.length);
        return result;
    }

    private void ensureWritten(size_t dataToWrite)
    {
        while(dataToWrite)
        {
            auto nwritten = dev.write(chain.window[$-dataToWrite .. $]);
            dataToWrite -= nwritten;
        }
    }

    mixin implementValve!(chain);
}

/**
 * An output pipe writes all its data to a given sink stream.  Any data in the
 * output pipe's window has been written to the stream.
 *
 * The returned iopipe has a function "flush" that will extend a chunk of data
 * and then release it immediately.
 *
 * Params: c = The input data to write to the stream.
 *         dev = The output stream to write data to. This must have a function
 *               `write` that can write a c.window.
 *
 * Returns: An iopipe that gives a view of the written data. Note that you
 *          don't have to do anything with the data.
 *
 */
auto outputPipe(Chain, Sink)(Chain c, Sink dev) if(isIopipe!Chain && is(typeof(dev.write(c.window)) == size_t))
{
    auto result = OutputPipe!(Chain, Sink)(dev, c);
    result.ensureWritten(result.window.length);
    return result;
}

@safe unittest
{
    // shim that simply verifies the data is correct
    static struct OutputStream
    {
        string verifyAgainst;
        size_t write(const(char)[] data)
        {
            assert(data.length <= verifyAgainst.length && data == verifyAgainst[0 .. data.length], verifyAgainst ~ " != " ~ data);
            verifyAgainst = verifyAgainst[data.length .. $];
            return data.length;
        }
    }

    auto pipe = "hello, world!".SimplePipe!(string, 5).outputPipe(OutputStream("hello, world!"));
    do
    {
        pipe.release(pipe.window.length);
    } while(pipe.extend(0) != 0);
}

/**
 * Process a given iopipe chain until it has reached EOF. This is accomplished
 * by extending and releasing continuously until extend returns 0.
 *
 * Params: c = The iopipe to process
 * Returns: The number of elements processed.
 */
size_t process(Chain)(auto ref Chain c)
{
    size_t result = 0;
    do
    {
        auto elementsInChain = c.window.length;
        result += elementsInChain;
        c.release(elementsInChain);
    } while(c.extend(0) != 0);

    return result;
}

@safe unittest
{
    assert("hello, world!".SimplePipe!(string, 5).process() == 13);
}

private struct IoPipeRange(Chain)
{
        Chain chain;
        private size_t extendRequestSize;
        bool empty() { return chain.window.length == 0; }
        auto front() { return chain.window; }
        void popFront()
        {
            chain.release(chain.window.length);
            chain.extend(extendRequestSize);
        }
}

/**
 * Convert an io pipe into a range, with each popFront releasing all the
 * current data and extending a specified amount.
 *
 * Note that the function may call extend once before returning, depending on
 * whether there is any data present or not.
 *
 * Params: extendRequestSize = The value to pass to c.extend when calling popFront
 *         c = The chain to use as backing for this range.
 */
auto asInputRange(size_t extendRequestSize = 0, Chain)(Chain c) if (isIopipe!Chain)
{
    if(c.window.length == 0)
        // attempt to prime the range, since empty will be true right away!
        c.extend(extendRequestSize);
    return IoPipeRange!Chain(c, extendRequestSize);
}

@safe unittest
{
    auto str = "abcdefghijklmnopqrstuvwxyz";
    foreach(elem; str.SimplePipe!(string, 5).asInputRange)
    {
        assert(elem == str[0 .. elem.length]);
        str = str[elem.length .. $];
    }
    assert(str.length == 0);
}

private struct IoPipeElemRange(Chain)
{
        Chain chain;
        private size_t extendRequestSize;
        bool empty() { return chain.window.length == 0; }
        auto front() { return chain.window[0]; }
        void popFront()
        {
            chain.release(1);
            if(chain.window.length == 0)
                chain.extend(extendRequestSize);
        }
}

/**
 * Convert an io pipe into a range of elements of the pipe. This effectively
 * converts an iopipe range of T into a range of T. Note that auto-decoding
 * does NOT happen still, so converting a string into an input range produces a
 * range of char. The range is extended when no more data is in the window.
 *
 * Note that the function may call extend once before returning, depending on
 * whether there is any data present or not.
 *
 * Params: extendRequestSize = The value to pass to c.extend when calling in
 *             popFront
 *         c = The chain to use as backing for this range.
 */
auto asElemRange(size_t extendRequestSize = 0, Chain)(Chain c) if (isIopipe!Chain)
{
    if(c.window.length == 0)
        c.extend(extendRequestSize);
    return IoPipeElemRange!Chain(c, extendRequestSize);
}

@safe unittest {
    auto str = "abcdefghijklmnopqrstuvwxyz";
    import std.algorithm : equal;
    import std.utf : byCodeUnit;
    assert(equal(str.byCodeUnit, SimplePipe!(string, 5)(str).asElemRange));
}

/**
 * Create an input source from a given Chain, and a given translation function/template.
 *
 * It is advisable to use a template or lambda that does not require a closure,
 * and is not a delegate from a struct that might move.
 *
 * The result is also alias-this'd to the chain, so it can be used as an iopipe also.
 *
 * Params:
 *    fun = Function that accepts as its first parameter the input chain (of
 *    type Chain), and as its second parameter, the buffer to read into. Only
 *    buffer types that are supported are used.
 *    c = The chain to read from
 */
template iosrc(alias fun, Chain)
{
    struct IOSource
    {
        Chain chain;
        size_t read(T)(T buf) if (is(typeof(fun(chain, buf)) == size_t))
        {
            return fun(chain, buf);
        }

        // We are just wrapping the chain, so allow usage of it completely
        alias chain this;
    }

    auto iosrc(Chain c)
    {
        return IOSource(c);
    }
}

// TODO: need to deal with general ranges.
import std.typecons;
alias ReleaseOnWrite = Flag!"releaseOnWrite";
/**
 * Write data from a random access range or character array into the given
 * iopipe. If relOnWrite is set to true (ReleaseOnWrite.yes), then all data
 * before the provided offset, and any new data written to the pipe is always
 * released. This is mainly useful for output buffers where you do not wish to
 * allocate extra space in the buffer, and wish to flush the buffer when it's
 * full.
 *
 * If relOnWrite is false, then the pipe data is not released, and you should
 * consider the "written" part to be the offset + the return value.
 *
 * Params: c = The iopipe chain to write to.
 *         data = The range to write to the chain.
 *         offset = The starting point to write the data.
 *         relOnWrite = If true, data is released as it is written, otherwise,
 *            it's not released.
 *
 * Returns: The number of elements written. This should match the elements of
 * the range, but could potentially be less if there wasn't a way to extend
 * more space and more space was needed.
 */
size_t writeBuf(ReleaseOnWrite relOnWrite = ReleaseOnWrite.yes, Chain, Range)(ref Chain c, Range data, size_t offset = 0)
    if (isIopipe!Chain && __traits(compiles, (c.window[0 .. 0] = data[0 .. 0])))
{
    assert(offset <= c.window.length);
    static if(relOnWrite)
    {
        // always release the offset bytes
        if(offset)
            c.release(offset);
        enum offsetVal = 0;
    }
    else
    {
        // define an alias to help write the common code.
        alias offsetVal = offset;
    }
    // trivial case
    if(data.length == 0)
        return 0;

    size_t result = data.length;

    if(c.window.length == offsetVal)
        c.extend(0);

    while(true)
    {
        const dlen = data.length;
        const wlen = c.window.length - offsetVal;
        if(wlen == 0)
            return result - dlen;
        if(wlen >= dlen)
        {
            c.window[offsetVal .. offsetVal + dlen] = data[];
            static if(relOnWrite)
            {
                c.release(dlen);
            }
            return result;
        }
        else
        {
            c.window[offsetVal .. $] = data[0 .. wlen];
            data = data[wlen .. $];
            static if(relOnWrite)
            {
                c.release(wlen);
            }
            else
            {
                offsetVal += wlen;
            }
            // no more available buffer to write. Need to fetch more.
            c.extend(0);
        }
    }
}

// TODO: need unittests for writeBuf
