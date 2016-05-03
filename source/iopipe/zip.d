/**
Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy at
           http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.zip;
import iopipe.buffer;
import iopipe.traits;
import etc.c.zlib;

enum CompressionFormat
{
    gzip,
    deflate,
    determineFromData
}

private struct UnzipPipe(Allocator, Chain)
{
    Chain chain;
    BufferManager!(ubyte, Allocator) buffer;
    z_stream zstream;
    this(Chain c, CompressionFormat format = CompressionFormat.determineFromData)
    {
        chain = c;
        buffer.extend(1024 * 8);
        zstream.next_in = chain.window.ptr;
        zstream.avail_in = cast(uint)chain.window.length;
        zstream.next_out = buffer.window.ptr;
        zstream.avail_out = cast(uint)buffer.window.length;
        if(inflateInit2(&zstream, 15 + (format == CompressionFormat.gzip ? 16 : format == CompressionFormat.determineFromData ? 32 : 0)) != Z_OK)
        {
            throw new Exception("Error initializing zip inflation");
        }

        // this likely does nothing, but just in case...
        chain.release(zstream.next_in - chain.window.ptr);
    }
    auto window() {
        return buffer.window[0 .. $-zstream.avail_out];
    }
    void release(size_t elements)
    {
        assert(elements + zstream.avail_out <= buffer.window.length);
        buffer.releaseFront(elements);
    }

    size_t extend(size_t elements)
    {
        if(zstream.zalloc == null)
            // stream is closed.
            return 0;
        if(elements == 0)
        {
            // TODO: what to do here?
            elements = 1024 * 8;
        }

        auto oldValid = window.length;
        if(zstream.avail_out < elements)
        {
            // need more space to unzip here.
            import std.algorithm.comparison : max;
            buffer.extend(max(elements - zstream.avail_out, buffer.avail()));

            // update the zstream
            zstream.next_out = buffer.window.ptr + oldValid;
            zstream.avail_out = cast(uint)(buffer.window.length - oldValid);
        }

        // now, unzip the data into the buffer. Stop when we have done at most
        // 2 extends on the input data.
        // TODO: is 2 extends the right metric?
        if(chain.window.length == 0)
        {
            // need at least some data to work with.
            chain.extend(0);
        }
        for(int i = 0; i < 2; ++i)
        {
            import std.stdio;
            zstream.next_in = chain.window.ptr;
            zstream.avail_in = cast(uint)chain.window.length;
            auto inflate_result = inflate(&zstream, Z_NO_FLUSH);
            chain.release(zstream.next_in - chain.window.ptr);
            if(inflate_result == Z_STREAM_END)
            {
                // all done.
                auto curAvailOut = zstream.avail_out;
                inflateEnd(&zstream);
                zstream = zstream.init;
                zstream.avail_out = curAvailOut;
                break;
            }
            else if(inflate_result == Z_OK)
            {
                // no more space available
                if(zstream.avail_out == 0)
                    break;
            }
            else
            {
                // error or unsupported condition
                import std.conv;
                throw new Exception("unhandled unzip condition " ~ to!string(inflate_result));
            }

            // read more data
            chain.extend(0);
        }

        // update the new data available
        return buffer.window.length - zstream.avail_out - oldValid;
    }

    mixin implementValve!chain;
}

auto unzip(Allocator = GCNoPointerAllocator, Chain)(Chain c, CompressionFormat format = CompressionFormat.determineFromData)
    if(isIopipe!(Chain) && is(windowType!Chain == ubyte[]))
{
    if(c.window.length == 0)
        c.extend(0);
    return UnzipPipe!(Allocator, Chain)(c, format);
}

private struct ZipPipe(Allocator, Chain)
{
    Chain chain;
    BufferManager!(ubyte, Allocator) buffer;
    z_stream zstream;
    int flushMode;

    this(Chain c, CompressionFormat format = CompressionFormat.deflate)
    {
        chain = c;
        buffer.extend(1024 * 8);
        zstream.next_in = chain.window.ptr;
        zstream.avail_in = cast(uint)chain.window.length;
        zstream.next_out = buffer.window.ptr;
        zstream.avail_out = cast(uint)buffer.window.length;
        flushMode = Z_NO_FLUSH;
        if(deflateInit2(&zstream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + (format == CompressionFormat.gzip ? 16 : 0),
                        8, Z_DEFAULT_STRATEGY) != Z_OK)
        {
            throw new Exception("Error initializing zip deflation");
        }

        // this likely does nothing, but just in case...
        chain.release(zstream.next_in - chain.window.ptr);
    }
    auto window()
    {
        return buffer.window[0 .. $-zstream.avail_out];
    }
    void release(size_t elements)
    {
        assert(elements + zstream.avail_out <= buffer.window.length);
        buffer.releaseFront(elements);
    }

    size_t extend(size_t elements)
    {
        if(zstream.zalloc == null)
            return 0;

        if(elements == 0)
        {
            // TODO: what to do here?
            elements = 1024 * 8;
        }

        auto oldValid = window.length;
        bool needMoreWriteSpace = false;
        while(window.length == oldValid)
        {
            // if we need to extend the buffer, do so.
            if(needMoreWriteSpace)
            {
                if(zstream.avail_out >= elements)
                {
                    // nudge up elements to ensure an extension
                    elements = zstream.avail_out + 1024;
                }
                needMoreWriteSpace = false;
            }
            if(zstream.avail_out < elements)
            {
                // need more space for zipping
                import std.algorithm.comparison : max;
                buffer.extend(max(elements - zstream.avail_out, buffer.avail()));

                // update the zstream
                zstream.next_out = buffer.window.ptr + oldValid;
                zstream.avail_out = cast(uint)(buffer.window.length - oldValid);
            }

            // ensure we have some data to zip
            if(flushMode == Z_NO_FLUSH && chain.window.length == 0)
            {
                if(chain.extend(0) == 0)
                {
                    flushMode = Z_FINISH;
                }
            }
            zstream.next_in = chain.window.ptr;
            zstream.avail_in = cast(uint)chain.window.length;
            auto deflate_result = deflate(&zstream, flushMode);
            chain.release(zstream.next_in - chain.window.ptr);

            if(deflate_result == Z_OK)
            {
                if(flushMode == Z_FINISH)
                {
                    // zlib doesn't have enough data to make progress
                    needMoreWriteSpace = true;
                }
            }
            else if(deflate_result == Z_BUF_ERROR)
            {
                // zlib needs more space to compress, or more data to read.
                if(flushMode != Z_FINISH && chain.extend(0) == 0)
                {
                    flushMode = Z_FINISH;
                }
                // need more write space
                needMoreWriteSpace = true;
            }
            else if(deflate_result == Z_STREAM_END)
            {
                // finished with the stream
                auto curAvailOut = zstream.avail_out;
                deflateEnd(&zstream);
                zstream = zstream.init;
                zstream.avail_out = curAvailOut;
                break;
            }
            else
            {
                import std.conv : to;
                throw new Exception("unhandled zip condition " ~ to!string(deflate_result));
            }
        }

        return buffer.window.length - zstream.avail_out - oldValid;
    }

    mixin implementValve!chain;
}

auto zip(Allocator = GCNoPointerAllocator, Chain)(Chain c, CompressionFormat format = CompressionFormat.init)
    if(isIopipe!(Chain) && is(windowType!Chain == ubyte[]))
{
    return ZipPipe!(Allocator, Chain)(c, format);
}
