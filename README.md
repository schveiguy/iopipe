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

In D, a very sophisticated set of constructs, called ranges, can use this same type of mechanism
to "wrap" one range with other ranges in order to build one range out of another, very similarly to
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
since everything is created at compile-time, it can all be optimized into the most efficient code possible.

iopipe does the same thing with buffered stream data.

## Concepts

You can read the original concepts.txt document that was used as reference when creating the library.

TODO: fill this out better

## Examples

Take a look at the example programs in the examples subdirectory.
* byline - A program that can read any text file of UTF8, UTF16, or UTF32 encoding, and output it to D's
  standard output stream
* convert - Takes the standard input of any encoding, and a parameter of the type of encoding to output,
  and converts the input to the output, adding a BOM if necessary.
  
## Building

iopipe is built with [dub](http://code.dlang.org). To build the examples, use the dub package command line:

`dub build :examplename`

## Documentation

No docs yet. iopipe.stream has been around for a long time, so it has pretty complete documentation. But the
rest is mostly undocumented.

## Testing

Not yet. Don't expect everyting to work. The performance I expect is likely not good yet either, as I have
not spent any time tweaking the code for this.

## Debugging

This one is a bit interesting. Since templates are used in large quantities, any stack traces you get will
be nigh unreadable. I'm not sure how to fix this.
