# iopipe
D language library for modular io

API documentation: http://schveiguy.github.io/iopipe

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

For example:
```D
import iopipe.textpipe;
import iopipe.zip;
import iopipe.bufpipe;
import iopipe.stream;

// open a zipfile, decompress it, detect the text encoding inside, and process
// lines that contain "foo"
void main(string[] args)
{
    openDev(args[1])            // open a file
         .bufd                  // buffer it
         .unzip                 // decompress it
         .runEncoded!((input) { // detect the text encoding and process it.
           import std.algorithm: filter, canFind;
           import std.stdio: writeln;
           foreach(line; input.byLineRange!false.filter!(a => canFind(a, "foo")))
               writeln("this line contains foo: ", line);
         });
}
```

## Basic Iopipe

A basic iopipe has 3 primitive functions which can be called. These are the
functions by which you can manipulate and process data. Typically, one is given
an iopipe which may need adjustments or reinterpretation, and it is simply a
matter of wrapping that iopipe in converters or processors that effect the
desired type of data, format of data, or rate of data.

A string of wrapped iopipes is called a *chain*. Most iopipes will use the
member name `chain` to denote the source iopipe from which data is retrieved.

### `SomeRange window`

This property gives a view into the data of the iopipe. The range should be a
random access, non-infinite range. For purposes of the iopipe library, narrow
character arrays are considered random access ranges of that code unit type.

Wrapping iopipes may return a subset of the wrapped window, or return the
window mapped into a different type.

NOTE: there are some assumptions in functions of the iopipe library that
all windows are arrays. Although most things *should* work with non-array
windows, it has not been thoroughly tested. Please file any issues if you have
a use case for a non-array window!

### `void release(size_t elements)`

Release the given number of elements from the beginning of the window. The
iopipe is *required* to release the specified data, such that the data no
longer appears in the window (how it accomplishes this may still hold the data
in the buffer somehow). To release more elements than are in the window results
in undefined behavior.

Previous calls or accesses to `window` should be discarded. Release is allowed
to change the data returned by `window`.

### `size_t extend(size_t elements)`

Extend the current window's end by the given number of elements. If the specified
number of elements is 0, then the iopipe should extend the optimal number of
elements if it can. This should attempt to extend *at least* one element.

Returns the number of elements extended. If no data can be extended, the return
value is 0, and it is considered the end of the stream in *most* cases. In some
cases, you may receive a 0 when an upstream valve is holding back some of the
data (this is defined by whomever implemented the valve). You are allowed to
attempt to extend an iopipe even when a previous call to extend returned 0.

## More Concepts

### Sources

Most iopipes start with a source. A source is a type that provides a `read`
member, accepting a buffer that is filled in with data from a data stream, and
returns how many elements were read. A `BufferManager` is used to manage the
allocation of the data, and turn the buffered data into a proper iopipe. The
iopipe library provides only one type of BufferManager at this time, which uses
an Allocator from `std.experimental.allocator` to allocate an array of data for
reading/writing.

As of this release, iopipe provides 2 basic sources, a `NullDev` which provides
uninitialized data, and a `ZeroDev` which provides zeroed data.

### Sinks

A Sink can take a buffer of data and write it to an external location (such as
a file or array). A sink is simply a type that defines a `write` member,
accepting the buffer to be written, and returning how many elements were
written.

The `outputPipe` function is the only iopipe wrapper that accepts a Sink. It
actually is simply another iopipe, and can be wrapped further for more
processing if necessary. It writes to the sink as data is extended BEFORE
providing the data further down the chain.

### IODev

The IODev class is provided as a simple mechanism to read and write file
descriptors. It is a bare-bones type that is both a Sink and a Source. It works
*only* on Posix systems at the moment. Windows support is coming later.

Note that this is not the only type of source or sink that iopipe will work
with. It just happens to be easy to implement. I expect people will want to use
their own device types (such as sockets or event-driven i/o).

### Valves

A Valve is a control point along the iopipe chain. The concept is that you can
use a valve to access some nested wrapped piece of the iopipe to change
parameters or effect certain behavior. The output system relies completely on
valves to work properly. The closest such item is accessed by using the `valve`
property of the iopipe (which must return by reference). If no more valves
exist, then this will not compile.

All wrapping iopipes that do not define a new valve must provide access to the
next upstream valve if it exists. This is essential to writing a proper iopipe
wrapper. There is a convenience mixin to allow this to happen automatically.

### Rebuffering

A concept not formalized in any type, but nonetheless important for iopipe,
when it is difficult or impossible to translate data in-place, it becomes
necessary to copy the data from its source format to a new buffer. This is done
by transforming the iopipe into a Source, and then using a new BufferManager to
buffer the data.

Note that a wrapping type can be both an iopipe AND a source, giving
flexibility whenever possible.

For examples of how this is done, see `iopipe.zip` and `iopipe.bufpipe.iosrc`.

### Construction

When constructing an iopipe, each wrapping function is passed a *copy* of the
previous chain. This means that all iopipes must be copyable *at least* before
processing begins. It is expected to treat each result of a wrapper uniquely,
and not make copies of half constructed data.

In some cases, it's necessary to have a single instance of an iopipe's
internals. This is to either adhere to some low-level library requirements or
to properly release resources. In this case, `std.typecons.RefCounted` is used
to fill this task.

## Examples

Take a look at the example programs in the examples subdirectory.
* byline - A program that can read any text file of UTF8, UTF16, or UTF32
  encoding, and output the line lengths to the standard output stream (this
  uses `std.stdio.writeln` to do this for now).
* convert - Takes the standard input of any text encoding, and a parameter of
  the type of encoding to output,
  and converts the input to the output, adding a BOM if necessary.
* zip - Compress the standard input to the standard output.
* unzip - Decompress the standard input to the standard output.
  
## Building

iopipe is built with [dub](http://code.dlang.org). To build the examples, use
the dub package command line:

`dub build :examplename`

## Documentation

Iopipe should be nearly completely documented. Please let me know if something
is missing or incorrect. I plan to provide a fully built ddoc output somewhere.

## Testing

iopipe unittests are fairly complete.
