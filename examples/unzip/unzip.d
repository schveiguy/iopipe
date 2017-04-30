import iopipe.zip;
import iopipe.stream;
import iopipe.bufpipe;

void main()
{
    // decompress the input into the output
    auto nbytes = openDev(0).bufd.unzip.outputPipe(openDev(1)).process();
    import std.stdio;
    stderr.writefln("decompressed %s bytes", nbytes);
}
