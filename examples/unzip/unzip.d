import iopipe.zip;
import iopipe.bufpipe;
import std.io;
import std.typecons : refCounted;

void main()
{
    // decompress the input into the output
    auto nbytes = File(0).refCounted.bufd.unzip.outputPipe(File(1).refCounted).process();
    import std.stdio : stderr;
    stderr.writefln("decompressed %s bytes", nbytes);
}
