/**
Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy at
           http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.traits;

/**
 * add window property to all arrays that allows any array to be the start of a pipe.
 * Returns: t
 */
auto window(T)(T[] t)
{
    return t;
}

/**
 * add extend function to all arrays that allows any array to be the start of a pipe chain.
 * Params: elements - Number of elements to extend, 0 to leave it up to the pipe chain.
 * Returns: Always returns 0 because arrays cannot be extended.
 */
size_t extend(T)(T[] t, size_t elements)
{
    return 0;
}

/**
 * Add release function to all arrays. This will remove the given number of elements
 * from the front of the array
 * Params: elements - Number of elements to release
 */
void release(T)(ref T[] t, size_t elements)
{
    assert(elements <= t.length);
    t = t[elements .. $];
}

unittest
{
    // ensure an array is a valid iopipe
    static assert(isIopipe!(ubyte[]));
    static assert(isIopipe!(string));
    static assert(isIopipe!(int[]));
}

/**
 * evaluates to true if the given type is a valid ioPipe
 */
template isIopipe(T)
{
    enum isIopipe = is(typeof(()
        {
            import std.range.primitives;
            import std.traits;
            T t;
            auto window = t.window;
            alias W = typeof(window);
            static assert(isNarrowString!W || isRandomAccessRange!W);
            auto x = t.extend(size_t(0));
            static assert(is(typeof(x) == size_t));
            t.release(size_t(0));
        }));
}

/**
 * Determine the type of the window of the given pipe type.
 */
template windowType(T)
{
    static if(is(typeof(T.window) == function))
        alias windowType = typeof(T.init.window());
    else
        alias windowType = typeof(T.init.window);
}

// I don't know how to do this in a better way...
private template propertyType(alias x)
{
    static if(is(typeof(x) == function))
        alias propertyType = typeof(x());
    else
        alias propertyType = typeof(x);
}

/**
 * Evaluates to true if the given io pipe has a valve
 */
template hasValve(T)
{
    import std.traits : hasMember;
    static if(hasMember!(T, "valve"))
        enum hasValve = isIopipe!T && isIopipe!(propertyType!(T.init.valve));
    else
        enum hasValve = false;
}

/**
 * Boilerplate for implementing a valve. If you don't define a custom valve,
 * you should always mixin this template in all your iopipe templates.
 */
mixin template implementValve(alias pipechain)
{
    static if(hasValve!(typeof(pipechain)))
        ref valve() { return pipechain.valve; }
}

/**
 * Determine the number of valves in the given pipeline
 */
template valveCount(T)
{
    static if(hasValve!(T))
    {
        enum valveCount = 1 + .valveCount!(typeof(T.init.valve));
    }
    else
    {
        enum valveCount = 0;
    }
}

/**
 * Evaluates to true if the given type is a valid buffer
 */
template isBuffer(T)
{
    enum isBuffer = is(typeof(()
        {
            import std.traits: isNarrowString;
            import std.range.primitives: isRandomAccessRange;
            T buf;
            auto w = buf.window;
            alias W = typeof(w);
            static assert(isNarrowString!W || isRandomAccessRange!W);
            auto x = buf.extendAndFlush(size_t.min, size_t.min, size_t.min);
            static assert(is(typeof(x) == size_t));
        }));
}
