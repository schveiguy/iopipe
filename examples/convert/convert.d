import iopipe.textpipe;
import iopipe.bufpipe;
import iopipe.stream;
import iopipe.buffer;
import std.range.primitives;

void doConvert(UTFType oEnc, Input)(Input input)
{
    import iopipe.valve;
    auto outputDev = new IODevice(1); // stdout
    auto oChain = NullDevice.init
        .bufferedSource(ArrayBuffer!(CodeUnit!oEnc)())
        .valved
        .encodeText!(oEnc)
        .outputPipe(outputDev)
        .autoValve // drive from the valve
        .textOutput;
    if(input.window.length > 0 && input.window.front != 0xfeff)
    {
        // write a BOM if not present
        put(oChain, dchar(0xfeff));
    }

    do
    {
        put(oChain, input.window);
        input.release(input.window.length);
    } while(input.extend(0) != 0);
    oChain.chain.flush();
}

void translate(UTFType iEnc, Input)(Input input, string outputEncoding)
{
    import std.conv : to;
    auto oEnc = outputEncoding.to!(UTFType);
    if(oEnc == iEnc)
    {
        // straight pass-through
        input.outputPipe(new IODevice(1)).process();
    }
    else
    {
        switch(oEnc)
        {
        case UTFType.UTF8:
            // all other encodings are wider. Need to use output range
            input.asText!iEnc.doConvert!(UTFType.UTF8);
            break;
        case UTFType.UTF16LE:
            // check for just changing byte order
            static if(iEnc == UTFType.UTF16BE)
            {
                // just changing byte order. Just do a byte swapper.
                input.arrayCastPipe!(ushort).byteSwapper.arrayCastPipe!(ubyte).outputPipe(new IODevice(1)).process();
            }
            else
            {
                // converting widths
                input.asText!iEnc.doConvert!(UTFType.UTF16LE);
            }
            break;
        case UTFType.UTF16BE:
            // check for just changing byte order
            static if(iEnc == UTFType.UTF16LE)
            {
                // just changing byte order. Just do a byte swapper.
                input.arrayCastPipe!(ushort).byteSwapper.arrayCastPipe!(ubyte).outputPipe(new IODevice(1)).process();
            }
            else
            {
                // converting widths
                input.asText!iEnc.doConvert!(UTFType.UTF16BE);
            }
            break;
        case UTFType.UTF32LE:
            // check for just changing byte order
            static if(iEnc == UTFType.UTF32BE)
            {
                // just changing byte order. Just do a byte swapper.
                input.arrayCastPipe!(uint).byteSwapper.arrayCastPipe!(ubyte).outputPipe(new IODevice(1)).process();
            }
            else
            {
                // converting widths
                input.asText!iEnc.doConvert!(UTFType.UTF32LE);
            }
            break;
        case UTFType.UTF32BE:
            // check for just changing byte order
            static if(iEnc == UTFType.UTF32LE)
            {
                // just changing byte order. Just do a byte swapper.
                input.arrayCastPipe!(uint).byteSwapper.arrayCastPipe!(ubyte).outputPipe(new IODevice(1)).process();
            }
            else
            {
                // converting widths
                input.asText!iEnc.doConvert!(UTFType.UTF32BE);
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
    auto dev = new IODevice(0).bufferedSource;
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
