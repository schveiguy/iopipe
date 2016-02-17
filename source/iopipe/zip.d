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

private struct UnzipPipe(BufType, Chain)
{
    Chain chain;
    BufType buffer;
    size_t released;
    size_t valid;
    z_stream zstream;
    this(Chain c, CompressionFormat format = CompressionFormat.determineFromData, BufType b = BufType.init)
    {
        chain = c;
        buffer = b;
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
        return buffer.window[released .. valid];
    }
    void release(size_t elements)
    {
        assert(released + elements <= valid);
        released += elements;
    }

    private bool streamIsClosed()
    {
        return zstream.zalloc == null;
    }
    size_t extend(size_t elements)
    {
        if(streamIsClosed)
            return 0;
        if(elements == 0)
        {
            // TODO: what to do here?
            elements = 1024 * 8;
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
            // update the zstream
            zstream.next_out = buffer.window.ptr + valid;
            zstream.avail_out = cast(uint)(buffer.window.length - valid);
        }

        // now, unzip the data into the buffer. Stop when we have done at most
        // 2 extends on the input data.
        // TODO: is 2 extends the right metric?
        if(chain.window.length == 0)
        {
            // need at least some data to work with.
            chain.extend(0);
        }
        auto oldvalid = valid - released;
        for(int i = 0; i < 2; ++i)
        {
            import std.stdio;
            zstream.next_in = chain.window.ptr;
            zstream.avail_in = cast(uint)chain.window.length;
            auto inflate_result = inflate(&zstream, Z_NO_FLUSH);
            valid = zstream.next_out - buffer.window.ptr;
            chain.release(zstream.next_in - chain.window.ptr);
            if(inflate_result == Z_STREAM_END)
            {
                // all done.
                inflateEnd(&zstream);
                zstream = zstream.init;
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
        if(valid > buffer.window.length)
        {
            import std.stdio;
            stderr.writefln("oops, %s, %s, %s, %s", valid, buffer.window.length, zstream.next_out, zstream.avail_out);
        }
        return valid - released - oldvalid;
    }
}

auto unzip(BufType = ArrayBuffer!ubyte, Chain)(Chain c, CompressionFormat format = CompressionFormat.determineFromData, BufType b = BufType.init)
    if(isBuffer!(BufType) && is(windowType!BufType == ubyte[]) &&
       isIopipe!(Chain) && is(windowType!Chain == ubyte[]))
{
    if(c.window.length == 0)
        c.extend(0);
    return UnzipPipe!(BufType, Chain)(c, format, b);
}

private struct ZipPipe(BufType, Chain)
{
    Chain chain;
    BufType buffer;
    size_t released;
    size_t valid;
    z_stream zstream;
    int flushMode;

    this(Chain c, CompressionFormat format = CompressionFormat.deflate, BufType b = BufType.init)
    {
        chain = c;
        buffer = b;
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
    auto window() {
        return buffer.window[released .. valid];
    }
    void release(size_t elements)
    {
        assert(released + elements <= valid);
        released += elements;
    }
    private bool streamIsClosed()
    {
        return zstream.zalloc == null;
    }

    size_t extend(size_t elements)
    {
        if(streamIsClosed)
            return 0;

        if(elements == 0)
        {
            // TODO: what to do here?
            elements = 1024 * 8;
        }

        auto oldElems = valid - released;
        bool needMoreWriteSpace = false;
        while(valid - released == oldElems)
        {
            // if we need to extend the buffer, do so.
            if(needMoreWriteSpace)
            {
                if(buffer.window.length - valid >= elements)
                {
                    // nudge up elements to ensure an extension
                    elements += 1024;
                }
                needMoreWriteSpace = false;
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
                // update the zstream
                zstream.next_out = buffer.window.ptr + valid;
                zstream.avail_out = cast(uint)(buffer.window.length - valid);
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
            valid = zstream.next_out - buffer.window.ptr;

            if(deflate_result == Z_OK)
            {
                if(flushMode == Z_FINISH)
                {
                    // zlib doesn't have enough data to make progress
                    elements += 1024;
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
                deflateEnd(&zstream);
                zstream = zstream.init;
                break;
            }
            else
            {
                import std.conv : to;
                throw new Exception("unhandled zip condition " ~ to!string(deflate_result));
            }
        }

        return valid - released - oldElems;
    }

}

auto zip(BufType = ArrayBuffer!ubyte, Chain)(Chain c, CompressionFormat format = CompressionFormat.init, BufType b = BufType.init)
    if(isBuffer!(BufType) && is(windowType!BufType == ubyte[]) &&
       isIopipe!(Chain) && is(windowType!Chain == ubyte[]))
{
    return ZipPipe!(BufType, Chain)(c, format, b);
}
