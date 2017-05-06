import iopipe.textpipe;
import iopipe.bufpipe;
import iopipe.stream;
import iopipe.buffer;
import std.range.primitives;

void doConvert(UTFType oEnc, Input)(Input input)
{
    /* This is the old way it was done. Left here for demonstration purposes
     import iopipe.valve;
    auto oChain = bufd!(CodeUnit!oEnc) // make a buffered source
        .push!(a => a
               .encodeText!(oEnc)
               .outputPipe(openDev(1))) // push to stdout.
        .textOutput; // turn into a standard output range
    if(!input.window.empty && input.window.front != 0xfeff)
    {
        // write a BOM if not present
        put(oChain, dchar(0xfeff));
    }

    foreach(w; input.ensureDecodeable.asInputRange)
        put(oChain, w);*/

    input.textConverter!(CodeUnit!oEnc, true).encodeText!(oEnc).outputPipe(openDev(1)).process();
}

void translate(UTFType iEnc, Input)(Input input, string outputEncoding)
{
    import std.conv : to;
    auto oEnc = outputEncoding.to!(UTFType);
    if(oEnc == iEnc)
    {
        // straight pass-through
        input.outputPipe(new IODev(1)).process();
    }
    else
    {
        switch(oEnc)
        {
        case UTFType.UTF8:
            // all other encodings are wider. Need to use output range
            input.decodeText!iEnc.doConvert!(UTFType.UTF8);
            break;
        case UTFType.UTF16LE:
            // check for just changing byte order
            static if(iEnc == UTFType.UTF16BE)
            {
                // just changing byte order. Just do a byte swapper.
                input.arrayCastPipe!(ushort).byteSwapper.arrayCastPipe!(ubyte).outputPipe(new IODev(1)).process();
            }
            else
            {
                // converting widths
                input.decodeText!iEnc.doConvert!(UTFType.UTF16LE);
            }
            break;
        case UTFType.UTF16BE:
            // check for just changing byte order
            static if(iEnc == UTFType.UTF16LE)
            {
                // just changing byte order. Just do a byte swapper.
                input.arrayCastPipe!(ushort).byteSwapper.arrayCastPipe!(ubyte).outputPipe(new IODev(1)).process();
            }
            else
            {
                // converting widths
                input.decodeText!iEnc.doConvert!(UTFType.UTF16BE);
            }
            break;
        case UTFType.UTF32LE:
            // check for just changing byte order
            static if(iEnc == UTFType.UTF32BE)
            {
                // just changing byte order. Just do a byte swapper.
                input.arrayCastPipe!(uint).byteSwapper.arrayCastPipe!(ubyte).outputPipe(new IODev(1)).process();
            }
            else
            {
                // converting widths
                input.decodeText!iEnc.doConvert!(UTFType.UTF32LE);
            }
            break;
        case UTFType.UTF32BE:
            // check for just changing byte order
            static if(iEnc == UTFType.UTF32LE)
            {
                // just changing byte order. Just do a byte swapper.
                input.arrayCastPipe!(uint).byteSwapper.arrayCastPipe!(ubyte).outputPipe(new IODev(1)).process();
            }
            else
            {
                // converting widths
                input.decodeText!iEnc.doConvert!(UTFType.UTF32BE);
            }
            break;
        default:
            assert(0);
        }
    }
}

void main(string[] args)
{
    // convert all data from input stream to given format
    auto dev = new IODev(0).bufd;
    dev.ensureElems(4);
    switch(dev.window.detectBOM)
    {
    case UTFType.Unknown:
    case UTFType.UTF8:
        dev.translate!(UTFType.UTF8)(args[1]);
        break;
    case UTFType.UTF16LE:
        dev.translate!(UTFType.UTF16LE)(args[1]);
        break;
    case UTFType.UTF16BE:
        dev.translate!(UTFType.UTF16BE)(args[1]);
        break;
    case UTFType.UTF32LE:
        dev.translate!(UTFType.UTF32LE)(args[1]);
        break;
    case UTFType.UTF32BE:
        dev.translate!(UTFType.UTF32BE)(args[1]);
        break;
    default:
        assert(0);
    }
}
