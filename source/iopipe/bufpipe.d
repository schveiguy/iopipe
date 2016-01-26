/**
Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy at
           http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.bufpipe;
import iopipe.buffer;
import iopipe.valve;
import std.range.primitives;

// simple array source processor
struct ArrayProcessor(T)
{
    T[] source;
    T[] window() { return source; }
    size_t extend(size_t elements) { return 0; }
    void release(size_t elements) { source = source[elements..$]; }
}

// prototypical processor, does nothing but extend/release when asked.
struct SimpleProcessor(Chain)
{
    Chain chain;
    size_t downstreamElements;
    auto window() { return chain.window[0..downstreamElements]; }
    size_t extend(size_t elements)
    {
        // normally, do processing in here
        auto left = chain.window.length - downstreamElements;
        if(elements == 0)
        {
            // special case
            if(left != 0)
            {
                downstreamElements += 1;
                return 1;
            }
            else
            {
                elements = chain.extend(0);
                downstreamElements += elements;
                return elements;
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

    void release(size_t elements)
    {
        downstreamElements -= elements;
        chain.release(elements);
    }

    mixin implementValve!(chain);
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
            sdata[$-1] = ((sdata[$-1] << 8) & 0xff00) |
                ((sdata[$-1] >> 8) & 0x00ff);
            sdata.popBack();
        }

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

// byteswap every T before passing down
auto byteSwapper(Chain)(Chain c)
{
    struct ByteSwapProcessor
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
    
    // need to byteswap existing data, since we only byteswap on extend
    swapBytes(c.window);
    return ByteSwapProcessor(c);
}

auto arrayConvert(T, Chain)(Chain c)
{
    struct ArrayConversionProcessor
    {
        Chain chain;
        alias UE = typeof(Chain.init.window()[0]);
        static if(UE.sizeof > T.sizeof)
        {
            ubyte offset;
            enum Ratio = UE.sizeof / T.sizeof;
            static assert(UE.sizeof % T.sizeof == 0); // only support multiple sizes
        }
        else
        {
            enum Ratio = T.sizeof / UE.sizeof;
            static assert(T.sizeof % UE.sizeof == 0);
        }

        auto window()
        {
            static if(UE.sizeof > T.sizeof)
                return (cast(T[])chain.window)[offset..$];
            else static if(UE.sizeof == T.sizeof)
                return cast(T[])chain.window;
            else
            {
                auto win = chain.window;
                auto extraElems = win.length % Ratio;
                    return cast(T[])chain.window[0..$-extraElems];
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

    return ArrayConversionProcessor(c);
}

// ensure at least a certain number of elements in a chain
// are available, unless EOF occurs.
size_t ensureElems(Chain)(ref Chain chain, size_t elems)
{
    while(chain.window.length < elems)
    {
        if(chain.extend(elems - chain.window.length) == 0)
            break;
    }
    return chain.window.length;
}

struct NullDevice
{
    size_t read(T)(T buf)
    {
        // null data doesn't matter
        return buf.length;
    }

    // write also does nothing
    alias write = read;
}

struct ZeroSource
{
    size_t read(T)(T buf)
    {
        // zero data
        buf[] = 0;
        return buf.length;
    }
}

auto bufferedSource(BufType, Source)(Source dev, BufType b)
{
    struct BufferedInputSource
    {
        Source dev;
        BufType buffer;
        size_t released;
        size_t valid;
        auto window() { return buffer.window[released .. valid]; }
        void release(size_t elements)
        {
            assert(released + elements <= valid);
            released += elements;
        }

        size_t extend(size_t elements)
        {
            if(elements == 0)
            {
                // use optimal read size
                elements = 1024 * 8; // TODO: figure out this size
            }

            if(buffer.window.length - valid < elements)
            {
                if(buffer.extendAndFlush(released, valid, elements) == 0)
                {
                    // extend without allocating
                    auto newBytes = buffer.window.length - (valid - released);
                    if(!newBytes)
                        // cannot extend.
                        return 0;
                    buffer.extendAndFlush(released, valid, newBytes);
                }
                valid -= released;
                released = 0;
            }
            auto nread = dev.read(buffer.window[valid..$]);
            valid += nread;
            return nread;
        }
    }

    return BufferedInputSource(dev, b);
}

auto bufferedSource(BufType = ArrayBuffer!ubyte, Source)(Source dev)
{
    auto b = BufType.createDefault();
    return bufferedSource(dev, b);
}

auto outputProcessor(Chain, Sink)(Chain c, Sink dev)
{
    struct OutputProcessor
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

        size_t flush()
        {
            // extend and then release all data
            extend(0);
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

    auto result = OutputProcessor(dev, c);
    result.ensureWritten(result.window.length);
    return result;
}

// run a chain until eof. Returns number of elements processed
size_t process(Chain)(Chain c)
{
    size_t result = 0;
    do
    {
        auto bytesInChain = c.window.length;
        result += bytesInChain;
        c.release(bytesInChain);
    } while(c.extend(0) != 0);

    return result;
}
