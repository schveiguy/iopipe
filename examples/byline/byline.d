import iopipe.textpipe;
import iopipe.bufpipe;
import iopipe.buffer;
import std.stdio;

bool doOutput = true;

void processLines(UTFType utfType, Dev)(Dev dev)
{
    import std.conv: to;
    if(doOutput)
        writeln("encoding is: ", utfType.to!string);
    auto lines = 0;
    foreach(l; dev.assumeText!utfType.byLineRange)
    {
        if(doOutput)
            writeln("read line length: ", l.length);
        ++lines;
    }
    writefln("number of lines: %s", lines);
}

void main(string[] args)
{
    import std.io;
    import std.typecons : refCounted;
    if(args.length > 1 && args[1] == "-nooutput")
        doOutput = false;
    File(0).refCounted.bufd.runWithEncoding!processLines;
    stdout.flush();
}
