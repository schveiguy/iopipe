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
    if(args.length > 1 && args[1] == "-nooutput")
        doOutput = false;
    openDev(0).bufd.runWithEncoding!processLines;
    stdout.flush();
}
