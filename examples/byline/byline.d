import iopipe.textpipe;
import iopipe.bufpipe;
import iopipe.stream;
import iopipe.buffer;
import std.stdio;

void processLines(UTFType utfType, Dev)(Dev dev)
{
    import std.conv: to;
    writeln("encoding is: ", utfType.to!string);
    foreach(l; dev.asText!(utfType).byLine)
    {
        write("read line: ", l);
    }
}

void main()
{
    import std.experimental.allocator;
    auto dev = new IODevice(0).bufferedSource(AllocatorBuffer!ubyte(theAllocator));
    dev.ensureElems(4);
    switch(dev.window.detectBOM)
    {
    case UTFType.Unknown:
    case UTFType.UTF8:
        dev.processLines!(UTFType.UTF8);
        break;
    case UTFType.UTF16LE:
        dev.processLines!(UTFType.UTF16LE);
        break;
    case UTFType.UTF16BE:
        dev.processLines!(UTFType.UTF16BE);
        break;
    case UTFType.UTF32LE:
        dev.processLines!(UTFType.UTF32LE);
        break;
    case UTFType.UTF32BE:
        dev.processLines!(UTFType.UTF32BE);
        break;
    default:
        assert(0);
    }

    stdout.flush();
}
