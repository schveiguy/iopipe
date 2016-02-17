import iopipe.zip;
import iopipe.stream;
import iopipe.bufpipe;

void main()
{
    // decompress the input into the output
    auto nbytes = bufferedSource(new IODevice(0)).unzip.outputPipe(new IODevice(1)).process();
    import std.stdio;
    stderr.writefln("decompressed %s bytes", nbytes);
}
