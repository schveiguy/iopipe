import iopipe.zip;
import iopipe.stream;
import iopipe.bufpipe;

void main()
{
    // decompress the input into the output
    auto nbytes = bufferedSource(new IODevice(0)).zip(CompressionFormat.gzip).outputPipe(new IODevice(1)).process();
    import std.stdio;
    stderr.writefln("compressed %s bytes", nbytes);
}
