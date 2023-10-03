/**
  Simple streams for use with iopipe
Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy
at http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.stream;

version(Have_io)
{
    import std.io;

    version(Posix)
    {
        /// Deprecated: use std.io directly
        deprecated alias IODev = IOObject!(File);

        /**
         * Construct an input stream based on the file descriptor
         *
         * params:
         * fd = The file descriptor to wrap
         *
         * Deprecated: Use https://code.dlang.org/io for low-level device i/o
         */
        deprecated("use std.io")
            auto openDev(int fd)
            {
                return ioObject(File(fd));
            }

        /**
         * Open a file by name.
         *
         * Deprecated: Use https://code.dlang.org/io for low-level device i/o
         */
        deprecated("use std.io")
            auto openDev(in char[] name, Mode mode = Mode.read | Mode.binary)
            {
                return ioObject(File(name, mode));
            }
    }
}


/**
 * A source that reads uninitialized data.
 */
struct NullDev
{
    /**
     * read the data. Always succeeds.
     */
    size_t read(T)(T buf) const
    {
        // null data doesn't matter
        return buf.length;
    }
}

/// Common instance of NullDev to use anywhere needed.
immutable NullDev nullDev;

/**
 * A source stream that always reads zeros, no matter what the data type is.
 */
struct ZeroDev
{
    size_t read(T)(T buf) const
    {
        // zero data
        buf[] = 0;
        return buf.length;
    }
}

/// Common instance of ZeroDev to use anywhere needed.
immutable ZeroDev zeroDev;

/// Convert output of response.receiveAsRange() from requests package to a device
// alias ResponseStreamDev = RangeOfSlicesDev!ReceiveAsRange;

/** Construct iopipe device from Range of slices.
 * Note on lifetime: Each individual slice returned by the range must be valid until popFront is called again. The device only copies data on a read call. 
 * Params:
 * 	RoS = Range of (ubyte[]) slices. 
 */
struct RangeOfSlicesDev(RoS) {
	static assert(isInputRange!(RoS) && is(ElementType!RoS == ubyte[]), "Must be compatible with ReceiveAsRange");
	RoS sourceRange;
	/// View on the data returned by sourceRange
	ubyte[] data;
	this(RoS sourceRange){
		this.sourceRange = sourceRange;
		if(!sourceRange.empty){
			data = this.sourceRange.front;
			this.sourceRange.popFront;
		}
	}

	/// Copy chunk of data from range into outbuf. 
	size_t read(ubyte[] outbuf){
		size_t datalen = data.length;
		size_t outlen = outbuf.length;
		if(datalen == 0){
			if(sourceRange.empty)
				return 0;
			data = sourceRange.front;
			sourceRange.popFront;
			datalen = data.length;
		}

		if(datalen<outlen){
			outbuf[0..datalen] = data[];
			data.length = 0; 
			return datalen;
		}else{
			outbuf[] = data[0..outlen];
			data = data[outlen..$];
			return outlen;
		}
	}

}
