# iopipe
D language library for modular io

iopipe is an input/output library for the D programming language that strives to be as close as
possible to the unix shell "pipe" io specification.

## Unix pipes model
In a unix shell, one "pipes" a command to another command using the pipe character `|`. For example
```
# find -name 'hello*' | grep world
./blah/hello_world
```

Such a command pipes the output of the `find` command to the input of the `grep` command

In D, a very elegant set of constructs, called ranges, can use this same type of mechanism
to "wrap" one range with other ranges, similarly to
building a pipeline of i/o with the unix shell.

```D
foreach(a; someArray.retro.map!(a => a * 3).filter!(a => a % 100 != 0))
{
   // a will consist of multiples of 3 from someArray, in reverse order,
   // but that are not also multiples of 100
   ...
}
```

The nice thing about this is that the pipeline is compiler-generated code, evaluated lazily. This
means, no new arrays are created, and the elements are generated on-demand when asked for. In addition,
since the pipeline is created at compile-time, it can all be optimized into the most efficient code possible.

iopipe attempts the same thing with buffered stream data.

## Concepts

You can read the original concepts.txt document that was used as reference when creating the library.

TODO: fill this out better

## Examples

Take a look at the example programs in the examples subdirectory.
* byline - A program that can read any text file of UTF8, UTF16, or UTF32 encoding, and output the line lengths to the standard output stream (this uses `std.stdio.writeln` to do this for now).
* convert - Takes the standard input of any encoding, and a parameter of the type of encoding to output,
  and converts the input to the output, adding a BOM if necessary.
  
## Building

iopipe is built with [dub](http://code.dlang.org). To build the examples, use the dub package command line:

`dub build :examplename`

## Documentation

Getting there. iopipe.stream has been around for a long time, so it has pretty complete documentation. But the rest has some missing pieces. Note that iopipe.stream is not the focus of this library, but a workable I/O stream object that can be used as a base for everything. iopipes can be used with ANY stream type that supports a read method or a write method. If one wants to adapt his or her own stream type to iopipes, one must define a sink or source object that forwards the calls as appropriate. bufferedInput should be the model.

## Testing

Not much yet. Don't expect everything to work. I have tweaked the code a bit to try and optimize the line processor as much as possible. The current code beats std.stdio.File.byLine on a straight UTF8 text file and \n as the delimeter (even when phobos uses speedup hacks such as getdelim). Using multibyte delimeters and different encodings, the performance is slightly worse, but I can't compare this to phobos as phobos doesn't properly support these cases.
