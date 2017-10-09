/**
Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy at
           http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.stream;

// for now, we only support posix systems. Need to add support for Windows.
version(Posix)
{
    import core.stdc.stdio; // for FILE
    private import core.sys.posix.fcntl;
    private import core.sys.posix.unistd;
    private import std.string : toStringz;
    /**
     * The basic device-based Input and Output stream.  This uses the OS's native
     * file handle to communicate using physical devices.
     */
    class IODev
    {
        enum OpenMode
        {
            Unknown,
            ReadOnly,
            WriteOnly,
            ReadWrite,
        }

        private
        {
            // the file descriptor
            // fd is set to -1 when the stream is closed
            int fd = -1;

            // This is purely used only to close the file when this IODev is
            // using the same file descriptor as a FILE *.
            FILE * _cfile;

            // flag indicating the destructor should close the stream. Used
            // when a File does not own the fd in question (set to false).
            bool _closeOnDestroy;

            // Identifies the mode that this device was opened with. If opened
            // using an existing file descriptor, or with a FILE *, this is set
            // to Unknown
            OpenMode _openMode = OpenMode.Unknown;
        }

        /**
         * Construct an input stream based on the file descriptor
         *
         * params:
         * fd = The file descriptor to wrap
         * closeOnDestroy = If set to true, the destructor will close the file
         * descriptor.  This does not affect the operation of close.
         */
        this(int fd, bool closeOnDestroy = true)
        {
            this.fd = fd;
            this._closeOnDestroy = closeOnDestroy;
        }

        /**
         * Construct an input stream based on a FILE *.  The only difference
         * between this and the fd version is the close routine will close the
         * FILE * if valid.
         *
         * params:
         * fstream = The FILE * instance to use for initialization.
         * closeOnDestroy = If set to true, the destructor will close the file
         * descriptor.  This does not affect the operation of close.
         */
        this(FILE * fstream, bool closeOnDestroy = true)
        {
            assert(fstream);
            this._cfile = fstream;
            this.fd = .fileno(fstream);
            this._closeOnDestroy = closeOnDestroy;
        }

        /**
         * Open a file.  the specification for mode is identical to the linux man
         * page for fopen
         */
        this(in char[] name, in char[] mode = "rb")
        {
            if(!mode.length)
                throw new Exception("error in mode specification");
            // first, parse the open mode
            char m = mode[0];
            switch(m)
            {
            case 'r': case 'a': case 'w':
                break;
            default:
                throw new Exception("error in mode specification");
            }
            bool rw = false;
            bool bflag = false;
            foreach(i, c; mode[1..$])
            {
                if(i > 1)
                    throw new Exception("Error in mode specification");
                switch(c)
                {
                case '+':
                    if(rw)
                        throw new Exception("Error in mode specification");
                    rw = true;
                    break;
                case 'b':
                    // valid, but does nothing
                    if(bflag)
                        throw new Exception("Error in mode specification");
                    bflag = true;
                    break;
                default:
                    throw new Exception("Error in mode specification");
                }
            }

            // create the flags
            int flags = void;
            if(rw)
            {
                flags = O_RDWR;
                _openMode = OpenMode.ReadWrite;
            }
            else
            {
                if(m == 'r')
                {
                    flags = O_RDONLY;
                    _openMode = OpenMode.ReadOnly;
                }
                else
                {
                    flags = O_WRONLY | O_CREAT;
                    _openMode = OpenMode.WriteOnly;
                }
            }
            if(!rw && m == 'w')
                flags |= O_TRUNC;
            this.fd = .open(toStringz(name), flags, S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH);
            if(this.fd < 0)
                throw new Exception("Error opening file, check errno");

            // perform a seek if necessary
            if(m == 'a')
            {
                seekEnd(0);
            }

            // we opened the file, make sure we close it.
            _closeOnDestroy = true;
        }

        private ulong _seek(long delta, int whence)
        {
            auto retval = .lseek(fd, delta, whence);
            if(retval < 0)
            {
                // TODO: probably need an I/O exception
                throw new Exception("seek failed, check errno");
            }
            return retval;
        }

        /**
         * Seek the stream.  seekCurrent seeks from the current stream position,
         * seekAboslute seeks to the given position offset from the beginning of
         * the stream, and seekEnd seeks to the posision offset bytes from the end
         * of the stream (backwards).
         *
         * Note, this throws an exception if seeking fails or isn't supported.
         *
         * params:
         * offset = bytes to seek.
         *
         * returns: The position of the stream from the beginning of the stream
         * after seeking, or ulong.max if this cannot be determined.
         */
        ulong seekCurrent(long offset)
        {
            return _seek(offset, SEEK_CUR);
        }

        /// ditto
        ulong seekAbsolute(ulong offset)
        {
            assert(offset <= long.max);
            return _seek(offset, SEEK_SET);
        }

        /// ditto
        ulong seekEnd(ulong offset)
        {
            assert(offset <= long.max);
            return _seek(-cast(long)offset, SEEK_END);
        }

        /**
         * Read data from the stream.
         *
         * Throws an exception if reading does not succeed.
         *
         * params: data = Location to store the data from the stream.  Only the
         * data read from the stream is filled in.  It is valid for read to return
         * less than the number of bytes requested *and* not be at EOF.
         *
         * returns: 0 on EOF, number of bytes read otherwise.
         */
        size_t read(ubyte[] data)
        {
            auto result = .read(fd, data.ptr, data.length);
            if(result < 0)
            {
                // TODO: need an I/O exception
                throw new Exception("read failed, check errno");
            }
            return cast(size_t)result;
        }

        /**
         * Write a chunk of data to the output stream
         *
         * returns the number of bytes written on success.
         *
         * If 0 is returned, then the stream cannot be written to.
         */
        size_t write(const(ubyte)[] data)
        {
            auto result = core.sys.posix.unistd.write(fd, data.ptr, data.length);
            if(result < 0)
            {
                // Should we check for EPIPE?  Not sure.
                //if(errno == EPIPE)
                //  return 0;
                throw new Exception("write failed, check errno");
            }
            return cast(size_t)result;
        }

        /// ditto
        alias put = write;

        /**
         * Close the stream.  This releases any resources from the object.
         */
        void close()
        {
            if(_cfile && .fclose(_cfile) == EOF)
                throw new Exception("fclose failed, check errno");
            else if(fd != -1 && .close(fd) < 0)
                throw new Exception("close failed, check errno");
            _cfile = null;
            fd = -1;
        }

        /**
         * Destructor.  This is used as a safety net, in case the stream isn't
         * closed before being destroyed in the GC.  It is recommended to close
         * deterministically using close, because there is no guarantee the GC will
         * call this destructor.
         *
         * If the IODev was designated not to close on destroy, the destructor
         * does not close the underlying handle.
         */
        ~this()
        {
            if(_closeOnDestroy)
            {
                if(_cfile) 
                {
                    // can't check this for errors, because we can't throw in a
                    // destructor.
                    .fclose(_cfile);
                }
                else if(fd != -1)
                {
                    // can't check this for errors, because we can't throw in a
                    // destructor.
                    .close(fd);
                }
            }
            _cfile = null;
            fd = -1;
        }

        /**
         * Get the OS-specific handle for this File
         */
        @property int handle()
        {
            return fd;
        }

        @property OpenMode openMode()
        {
            return _openMode;
        }
    }

    /**
     * Convenience function to open a file without using the new operator.
     */
    IODev openDev(Args...)(Args args) if (is(typeof(new IODev(args))))
    {
        return new IODev(args);
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
