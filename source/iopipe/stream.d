/**
  Simple streams for use with iopipe
Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy
at http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.stream;
import std.io;

alias IODev = IOObject!(File);

/**
 * Construct an input stream based on the file descriptor
 *
 * params:
 * fd = The file descriptor to wrap
 */
auto openDev(int fd)
{
    return ioObject(File(fd));
}

/**
 * Open a file.  the specification for mode is identical to the linux man
 * page for fopen
 */
auto openDev(in char[] name, Mode mode)
{
    return ioObject(File(name, mode));
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
