/**
Copyright: Copyright Steven Schveighoffer 2017.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy at
           http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.zip;
import iopipe.traits;
import iopipe.buffer;
import iopipe.bufpipe;
import etc.c.zlib;

enum CompressionFormat
{
    gzip,
    deflate,
    determineFromData
}

// this struct is the basis for the zip/unzip mechanisms. It is essentially an
// iopipe with the z_stream piece added. Used as an iopipe, it's just
// equivalent to chain. However, it provides a mechanism to read the data into
// a compressed/uncompressed format. In that sense, it's more like a source.
// But it needs bufpipe.iosrc to convert to a true Source.
private struct ZipPipe(Chain)
{
    import std.typecons: RefCounted, RefCountedAutoInitialize;
    Chain chain;
    // zstream cannot be moved once initialized, as it has internal pointers to itself.
    RefCounted!(z_stream, RefCountedAutoInitialize.no) zstream;
    int flushMode;
    alias chain this;

    // convenience, because this is so long and painful!
    private z_stream *zstrptr()
    {
        return &zstream.refCountedPayload();
    }

    private void initForInflate(CompressionFormat format)
    {
        zstream.refCountedStore.ensureInitialized;
        zstream.next_in = chain.window.ptr;
        zstream.avail_in = cast(uint)chain.window.length;
        int windowbits = 15;
        switch(format) with(CompressionFormat)
        {
        case gzip:
            windowbits += 16;
            break;
        case determineFromData:
            windowbits += 32;
            break;
        case deflate:
        default:
            // use 15
            break;
        }
        if(inflateInit2(zstrptr, windowbits) != Z_OK)
        {
            throw new Exception("Error initializing zip inflation");
        }

        // just in case inflateinit consumed some bytes.
        chain.release(zstream.next_in - chain.window.ptr);
    }

    private void initForDeflate(CompressionFormat format)
    {
        zstream.refCountedStore.ensureInitialized();
        zstream.next_in = chain.window.ptr;
        zstream.avail_in = cast(uint)chain.window.length;
        flushMode = Z_NO_FLUSH;
        int windowbits = 15;
        switch(format) with(CompressionFormat)
        {
        case gzip:
            windowbits += 16;
            break;
        case deflate:
        default:
            // use 15
            break;
        }

        if(deflateInit2(zstrptr, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowbits,
                        8, Z_DEFAULT_STRATEGY) != Z_OK)
        {
            throw new Exception("Error initializing zip deflation");
        }

        // just in case inflateinit consumed some bytes.
        chain.release(zstream.next_in - chain.window.ptr);
    }

    private size_t doInflate(ubyte[] target)
    {
        if(target.length == 0 || zstream.zalloc == null)
            // no data requested, or stream is closed
            return 0;
        zstream.next_out = target.ptr;
        zstream.avail_out = cast(uint)target.length;

        // now, unzip the data into the buffer. Stop when we have done at most
        // 2 extends on the input data.
        if(chain.window.length == 0)
        {
            // need at least some data to work with.
            chain.extend(0);
        }
        for(int i = 0; i < 2; ++i)
        {
            zstream.next_in = chain.window.ptr;
            zstream.avail_in = cast(uint)chain.window.length;
            auto inflate_result = inflate(zstrptr, Z_NO_FLUSH);
            chain.release(zstream.next_in - chain.window.ptr);
            if(inflate_result == Z_STREAM_END)
            {
                // all done.
                size_t result = target.length - zstream.avail_out;
                inflateEnd(zstrptr);
                zstream = z_stream.init;
                return result;
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

        // return the number of bytes that were inflated
        return target.length - zstream.avail_out;
    }

    private size_t doDeflate(ubyte[] target)
    {
        if(target.length == 0 || zstream.zalloc == null)
            // no data requested, or stream is closed
            return 0;

        zstream.next_out = target.ptr;
        zstream.avail_out = cast(uint)target.length;

        while(zstream.avail_out == target.length) // while we haven't written anything yet
        {
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
            auto deflate_result = deflate(zstrptr, flushMode);
            chain.release(zstream.next_in - chain.window.ptr);

            if(deflate_result == Z_OK)
            {
                if(flushMode == Z_FINISH)
                {
                    // zlib doesn't have enough data to make progress
                    break;
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
                break;
            }
            else if(deflate_result == Z_STREAM_END)
            {
                // finished with the stream
                auto result = target.length - zstream.avail_out;
                deflateEnd(zstrptr);
                zstream = z_stream.init;
                return result;
            }
            else
            {
                import std.conv : to;
                throw new Exception("unhandled zip condition " ~ to!string(deflate_result));
            }
        }
        return target.length - zstream.avail_out;
    }
}

auto unzipSrc(Chain)(Chain c, CompressionFormat format = CompressionFormat.determineFromData)
    if(isIopipe!(Chain) && is(WindowType!Chain == ubyte[]))
{
    if(c.window.length == 0)
        c.extend(0);
    auto zsrc = iosrc!((c, b) => c.doInflate(b))(ZipPipe!(Chain)(c));
    // initialize the unzip stream.
    zsrc.initForInflate(format);
    return zsrc;
}

auto zipSrc(Chain)(Chain c, CompressionFormat format = CompressionFormat.init)
    if(isIopipe!(Chain) && is(WindowType!Chain == ubyte[]))
{
    if(c.window.length == 0)
        c.extend(0);
    auto zsrc = iosrc!((c, b) => c.doDeflate(b))(ZipPipe!(Chain)(c));
    // initialize the unzip stream.
    zsrc.initForDeflate(format);
    return zsrc;
}

auto unzip(Allocator = GCNoPointerAllocator, Chain)(Chain c, CompressionFormat format = CompressionFormat.determineFromData)
    if(isIopipe!(Chain) && is(WindowType!Chain == ubyte[]))
{
    return unzipSrc(c, format).bufd!(ubyte, Allocator);
}

auto zip(Allocator = GCNoPointerAllocator, Chain)(Chain c, CompressionFormat format = CompressionFormat.init)
    if(isIopipe!(Chain) && is(WindowType!Chain == ubyte[]))
{
    return zipSrc(c, format).bufd!(ubyte, Allocator);
}
