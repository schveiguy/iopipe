import iopipe.zip;
import iopipe.stream;
import iopipe.bufpipe;

void main()
{
    // decompress the input into the output
    auto nbytes = bufd(openDev(0)).zip(CompressionFormat.gzip).outputPipe(openDev(1)).process();
    import std.stdio;
    stderr.writefln("compressed %s bytes", nbytes);
}
