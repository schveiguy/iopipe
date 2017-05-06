import iopipe.textpipe;
import iopipe.bufpipe;
import iopipe.stream;
import iopipe.buffer;
import std.stdio;

bool doOutput = true;

void processLines(UTFType utfType, Dev)(Dev dev)
{
    import std.conv: to;
    if(doOutput)
        writeln("encoding is: ", utfType.to!string);
    auto lines = 0;
    foreach(l; dev.decodeText!(utfType).byLine.asInputRange)
    {
        if(doOutput)
            writeln("read line length: ", l.length);
        ++lines;
    }
    writefln("number of lines: %s", lines);
}

void main(string[] args)
{
    if(args.length > 1 && args[1] == "-nooutput")
        doOutput = false;
    auto dev = openDev(0).bufd;
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
