/**
  Compression/decompression with iopipes.

Copyright: Copyright Steven Schveighoffer 2017.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy
           at http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.zip;
import iopipe.traits;
import iopipe.buffer;
import etc.c.zlib;

// separate these out, to avoid having to deal with unnecessary out of bounds
// checks
// note, zlib uses uint, so we need to deal with issues with larger
// than uint.max window length.
private @trusted void setInput(ref z_stream str, const(ubyte)[] win) @nogc nothrow pure
{
    str.avail_in = win.length > uint.max ? uint.max : cast(uint)win.length;
    str.next_in = win.ptr;
}

private @trusted void setOutput(ref z_stream str, ubyte[] win) @nogc nothrow pure
{
    str.avail_out = win.length > uint.max ? uint.max : cast(uint)win.length;
    str.next_out = win.ptr;
}

/**
 * Enum for specifying the desired or expected compression format.
 */
enum CompressionFormat
{
    /// GZIP format
    gzip,
    /// Deflate (zip) format
    deflate,
    /// Auto-detect the format by reading the data (unzip only)
    determineFromData
}

private struct ZipSrc(Chain)
{
    import iopipe.refc;
    Chain chain;
    // zstream cannot be moved once initialized, as it has internal pointers to itself.
    RefCounted!(z_stream) zstream;
    int flushMode;

    // convenience, because this is so long and painful!
    private @property @system z_stream *zstrptr()
    {
        return &zstream._get();
    }

    this(Chain c, CompressionFormat format)
    {
        chain = c;
        zstream = z_stream().refCounted;
        zstream.setInput(chain.window);
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

        if((() @trusted => deflateInit2(zstrptr, Z_DEFAULT_COMPRESSION,
                        Z_DEFLATED, windowbits, 8, Z_DEFAULT_STRATEGY))() != Z_OK)
        {
            throw new Exception("Error initializing zip deflation");
        }

        // just in case inflateinit consumed some bytes.
        chain.release(chain.window.length - zstream.avail_in);
    }

    size_t read(ubyte[] target)
    {
        if(target.length == 0 || zstream.zalloc == null)
            // no data requested, or stream is closed
            return 0;

        // zlib works with 32-bit lengths ONLY, so truncate here to avoid math
        // issues.
        if(target.length > uint.max)
            target = target[0 .. uint.max];
        zstream.setOutput(target);

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
            zstream.setInput(chain.window);
            auto deflate_result = (() @trusted => deflate(zstrptr, flushMode))();
            chain.release(chain.window.length - zstream.avail_in);

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
                () @trusted {deflateEnd(zstrptr);}();
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

    mixin implementValve!chain;
}

private struct UnzipSrc(Chain)
{
    import iopipe.refc;
    Chain chain;
    // zstream cannot be moved once initialized, as it has internal pointers to itself.
    RefCounted!(z_stream) zstream;
    private CompressionFormat openedFormat;

    // convenience, because this is so long and painful!
    private @property @system z_stream *zstrptr()
    {
        return &zstream._get();
    }

    private void ensureMoreData(bool setupInput = false)
    {
        if(chain.window.length < 4096) // don't overallocate
        {
            cast(void)chain.extend(0);
            setupInput = true;
        }
        if(setupInput)
        {
            zstream.setInput(chain.window);
        }
    }

    private void initializeStream()
    {
        int windowbits = 15;
        switch(openedFormat) with(CompressionFormat)
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
        if((() @trusted => inflateInit2(zstrptr, windowbits))() != Z_OK)
        {
            throw new Exception("Error initializing zip inflation");
        }

        // just in case inflateinit consumed some bytes.
        chain.release(chain.window.length - zstream.avail_in);
        ensureMoreData();
    }

    this(Chain c, CompressionFormat format)
    {
        chain = c;
        openedFormat = format;
        zstream = z_stream().refCounted;
        ensureMoreData(true);
        initializeStream();
    }

    size_t read(ubyte[] target)
    {
        if(target.length == 0)
            // no data requested
            return 0;

        if(zstream.zalloc == null)
        {
            // stream not opened. Try opening it if there is data available.
            // This happens for concatenated streams.
            ensureMoreData(true);
            if(chain.window.length == 0)
                // no more data left
                return 0;
            initializeStream();
        }


        // zlib works with 32-bit lengths ONLY, so truncate here to avoid math
        // issues.
        if(target.length > uint.max)
            target = target[0 .. uint.max];
        zstream.setOutput(target);

        // now, unzip the data into the buffer. Stop when we have done at most
        // 2 extends on the input data.
        foreach(i; 0 .. 2)
        {
            ensureMoreData();
            auto inflate_result = (() @trusted => inflate(zstrptr, Z_NO_FLUSH))();
            chain.release(chain.window.length - zstream.avail_in);
            if(inflate_result == Z_STREAM_END)
            {
                // all done?
                size_t result = target.length - zstream.avail_out;
                () @trusted {inflateEnd(zstrptr);}();
                zstream = z_stream.init;
                if(result == 0)
                {
                    // for some reason we had an open stream, but Z_STREAM_END
                    // happened without any more data coming out. In this case,
                    // returning 0 would indicate the end of the stream, but
                    // there may be more data if we try again (for concatenated
                    // streams).
                    return read(target);
                }
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
        }

        // return the number of bytes that were inflated
        return target.length - zstream.avail_out;
    }

    mixin implementValve!chain;
}

/**
 * Get a stream source that unzips an iopipe of ubytes. The source stream
 * should be compressed in the appropriate format.
 *
 * This is the source that `unzip` uses to decompress.
 *
 * Params:
 *     c = The input iopipe that provides the compressed data. The window type
 *         MUST be implicitly convertable to an array of const ubytes.
 *     format = The specified format of the data, leave the default to autodetect.
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
 *    c = The input iopipe that provides the data to compress. The window type
 *        MUST be implicitly convertable to an array of const ubytes.
 *    format = The specified format of the compressed data.
 * Returns:
 *    An input stream whose `read` method compresses the input iopipe data into
 *    the given buffer.
 */
auto zipSrc(Chain)(Chain c, CompressionFormat format = CompressionFormat.gzip) @safe
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
 *     Allocator = The allocator to use for buffering the data.
 *     c = The input iopipe that provides the compressed data. The window type
 *         MUST be implicitly convertable to an array of const ubytes.
 *     format = The format of the input iopipe compressed data. Leave as
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
 *     Allocator = The allocator to use for buffering the data.
 *     c = The input iopipe that provides the input data. The window type
 *         MUST be implicitly convertable to an array of const ubytes.
 *     format = The desired format of the compressed data. The default is gzip.
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
@safe unittest
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
        this(ref ubyte[] target) @trusted
        {
            result = &target;
        }
        size_t write(ubyte[] data)
        {
            (*result) ~= data;
            return data.length;
        }
    }

    ubyte[] zipped;
    realData.zip.outputPipe(ByteWriter(zipped)).process();

    // zipped contains the zipped data, make sure it's less (it should be,
    // plenty of opportunity to compress!
    assert(zipped.length < realData.length);

    ubyte[] unzipped;
    zipped.unzip.outputPipe(ByteWriter(unzipped)).process();

    assert(unzipped == realData);
}
