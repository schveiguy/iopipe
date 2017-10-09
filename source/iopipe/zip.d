/**
Copyright: Copyright Steven Schveighoffer 2017.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy at
           http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.zip;
import iopipe.traits;
import iopipe.buffer;
import etc.c.zlib;

enum CompressionFormat
{
    gzip,
    deflate,
    determineFromData
}

private struct ZipSrc(Chain)
{
    import std.typecons: RefCounted, RefCountedAutoInitialize;
    Chain chain;
    // zstream cannot be moved once initialized, as it has internal pointers to itself.
    RefCounted!(z_stream, RefCountedAutoInitialize.no) zstream;
    int flushMode;

    // convenience, because this is so long and painful!
    private @property z_stream *zstrptr()
    {
        return &zstream.refCountedPayload();
    }

    this(Chain c, CompressionFormat format)
    {
        chain = c;
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

    size_t read(ubyte[] target)
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

private struct UnzipSrc(Chain)
{
    import std.typecons: RefCounted, RefCountedAutoInitialize;
    Chain chain;
    // zstream cannot be moved once initialized, as it has internal pointers to itself.
    RefCounted!(z_stream, RefCountedAutoInitialize.no) zstream;

    // convenience, because this is so long and painful!
    private @property z_stream *zstrptr()
    {
        return &zstream.refCountedPayload();
    }

    this(Chain c, CompressionFormat format)
    {
        chain = c;
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

    size_t read(ubyte[] target)
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
        foreach(i; 0 .. 2)
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
}

/**
 * Get a stream source that unzips an iopipe of ubytes. The source stream
 * should be compressed in the appropriate format.
 *
 * This is the source that `unzip` uses to decompress.
 *
 * Params:
 *     c - The input iopipe that provides the compressed data. The window type
 *         MUST be implicitly convertable to an array of const ubytes.
 *     format - The specified format of the data, leave the default to autodetect.
 * Returns:
 *     An input stream whose `read` method decompresses the input iopipe into
 *     the given buffer.
 */
auto unzipSrc(Chain)(Chain c, CompressionFormat format = CompressionFormat.determineFromData)
    if(isIopipe!(Chain) && is(WindowType!Chain : const(ubyte)[]))
{
    if(c.window.length == 0)
        cast(void)c.extend(0);
    return UnzipSrc!(Chain)(c, format);
}

/**
 * Get a stream source that compresses an iopipe of ubytes with the given format.
 *
 * This is the source that `zip` uses to compress data.
 *
 * Params:
 *    c - The input iopipe that provides the data to compress. The window type
 *        MUST be implicitly convertable to an array of const ubytes.
 *    format - The specified format of the compressed data.
 * Returns:
 *    An input stream whose `read` method compresses the input iopipe data into
 *    the given buffer.
 */
auto zipSrc(Chain)(Chain c, CompressionFormat format = CompressionFormat.gzip)
    if(isIopipe!(Chain) && is(WindowType!Chain : const(ubyte)[]))
{
    if(c.window.length == 0)
        cast(void)c.extend(0);
    return ZipSrc!(Chain)(c, format);
}

/**
 * Wrap an iopipe that contains compressed data into an iopipe containing the
 * decompressed data. Data is not decompressed in place, so an extra buffer is
 * created to hold it.
 *
 * Params:
 *     Allocator - The allocator to use for buffering the data.
 *     c - The input iopipe that provides the compressed data. The window type
 *         MUST be implicitly convertable to an array of const ubytes.
 *     format - The format of the input iopipe compressed data. Leave as
 *     default to detect from the data itself.
 * Returns:
 *     An iopipe whose data is the decompressed ubyte version of the input stream.
 */
auto unzip(Allocator = GCNoPointerAllocator, Chain)(Chain c, CompressionFormat format = CompressionFormat.determineFromData)
    if(isIopipe!(Chain) && is(WindowType!Chain : const(ubyte)[]))
{
    import iopipe.bufpipe: bufd;
    return unzipSrc(c, format).bufd!(ubyte, Allocator);
}

/**
 * Wrap an iopipe of ubytes into an iopipe containing the compressed data from
 * that input. Data is not compressed in place, so an extra buffer is created
 * to hold it.
 *
 * Params:
 *     Allocator - The allocator to use for buffering the data.
 *     c - The input iopipe that provides the input data. The window type
 *         MUST be implicitly convertable to an array of const ubytes.
 *     format - The desired format of the compressed data. The default is gzip.
 * Returns:
 *     An iopipe whose data is the compressed ubyte version of the input stream.
 */
auto zip(Allocator = GCNoPointerAllocator, Chain)(Chain c, CompressionFormat format = CompressionFormat.init)
    if(isIopipe!(Chain) && is(WindowType!Chain : const(ubyte)[]))
{
    import iopipe.bufpipe: bufd;
    return zipSrc(c, format).bufd!(ubyte, Allocator);
}

// I won't pretend to know what the zip format should look like, so just verify that
// we can do some kind of compression and return to the original.
unittest
{
    import std.range: cycle, take;
    import std.array: array;
    import std.string: representation;
    import iopipe.bufpipe;

    auto realData = "hello, world!".representation.cycle.take(100_000).array;
    // sanity check
    assert(realData.length == 100_000);

    // zip the data
    static struct ByteWriter
    {
        ubyte[] *result;
        size_t write(ubyte[] data)
        {
            (*result) ~= data;
            return data.length;
        }
    }

    ubyte[] zipped;
    realData.zip.outputPipe(ByteWriter(&zipped)).process();

    // zipped contains the zipped data, make sure it's less (it should be,
    // plenty of opportunity to compress!
    assert(zipped.length < realData.length);

    ubyte[] unzipped;
    zipped.unzip.outputPipe(ByteWriter(&unzipped)).process();

    assert(unzipped == realData);
}
