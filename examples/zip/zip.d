import iopipe.zip;
import iopipe.bufpipe;
import std.io;
import std.typecons : refCounted;

void main()
{
    // decompress the input into the output
    auto nbytes = bufd(File(0).refCounted).zip(CompressionFormat.gzip).outputPipe(File(1).refCounted).process();
    import std.stdio : stderr;
    stderr.writefln("compressed %s bytes", nbytes);
}
