import iopipe.textpipe;
import iopipe.bufpipe;
import iopipe.stream;
import iopipe.valve;
import std.format;

// returns number of matches found
size_t performSearch(UTFType utfType, Dev)(Dev dev, size_t contextLines, string[] terms)
{
    // repeat the input to the output. Don't transcode
    alias Char = CodeUnit!utfType;
    auto output = bufd!Char.push!(a => a
         .encodeText!(utfType)
         .outputPipe(openDev(1)));

    // output range that doesn't auto-decode
    void writeOutput(const(Char)[] data)
    {
        if(data.length) // yes, put sometimes sends in 0 elements.
        {
            output.ensureElems(data.length);
            output.window[0 .. data.length] = data;
            output.release(data.length);
        }
    }

    // keep N lines in context before the current line. Add one element for a
    // sentinel (will always be 0)
    size_t[] lineEnds = new size_t[contextLines + 1];
    //size_t lineNum = 0;
    size_t toPrint = 0;
    size_t matches = 0;
    bool printElipses = false;

    auto linepipe = dev.assumeText!utfType.byLine;

    while(true)
    {
        import std.algorithm.searching : canFind, any;
        // every time we hit a match, we are going to print all the lines of
        // context before, and then print all the lines of context after.
        auto lstart = linepipe.window.length;
        if(linepipe.extend() == 0)
            break; // we are done
        //++lineNum;
        auto lineNum = linepipe.segments;

        // check to see if we found any search terms in here
        auto curLine = linepipe.window[lstart .. $];
        if(terms.any!(a => curLine.canFind(a)))
        {
            ++matches;
            if(printElipses)
            {
                writeOutput("...\n");
                printElipses = false;
            }
            foreach_reverse(i; 1 .. lineEnds.length)
            {
                if(lineEnds[i] != lineEnds[i-1])
                {
                    formattedWrite(&writeOutput, cast(immutable(Char)[])"%s : %s", lineNum - i, linepipe.window[lineEnds[i] .. lineEnds[i - 1]]);
                }
            }

            // print the matched line
            formattedWrite(&writeOutput,cast(immutable(Char)[])"%s*: %s", lineNum, curLine);
            toPrint = contextLines;

            // release all data that we printed
            lineEnds[] = 0;
            linepipe.release(linepipe.window.length);
        }
        else if(toPrint > 0)
        {
            // keep printing lines
            formattedWrite(&writeOutput, cast(immutable(Char)[])"%s : %s", lineNum, linepipe.window);
            --toPrint;
            // this line has been printed, so don't save it in the buffer.
            linepipe.release(linepipe.window.length);
        }
        else if(contextLines == 0)
        {
            // we don't ever print context lines.
            linepipe.release(linepipe.window.length);
            printElipses = true;
        }
        else
        {
            // store the line ending information, but don't print anything
            auto toRelease = lineEnds[$-2];
            if(toRelease > 0)
            {
                linepipe.release(toRelease);
                printElipses = true;
            }
            foreach_reverse(i; 1 .. lineEnds.length-1)
                lineEnds[i] = lineEnds[i-1] - toRelease;
            lineEnds[0] = linepipe.window.length;
        }
    }
    return matches;
}

int main(string[] args)
{
    import std.getopt;
    import std.stdio;
    size_t contextLines = 2;
    bool useRing;
    auto helpInfo = args.getopt("context", &contextLines, "ring", &useRing);
    if(helpInfo.helpWanted)
    {
        defaultGetoptPrinter("usage", helpInfo.options);
        return 1;
    }

    args = args[1 .. $];
    if(args.length == 0)
    {
        stderr.writeln("Need search parameters");
        return 1;
    }

    size_t result;
    if(useRing)
        result = openDev(0).rbufd.runWithEncoding!performSearch(contextLines, args);
    else
        result = openDev(0).bufd.runWithEncoding!performSearch(contextLines, args);
    writefln("matched %s lines", result);
    return 0;
}
