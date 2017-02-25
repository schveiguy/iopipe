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

    // release is the only testworthy function
    import std.range: iota;
    import std.array: array;

    auto arr = iota(100).array;

    auto oldarr = arr;
    arr.release(20);
    assert(oldarr[20 .. $] == arr);
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
            auto t = T.init;
            auto window = t.window;
            alias W = typeof(window);
            static assert(isNarrowString!W || isRandomAccessRange!W);
            auto x = t.extend(size_t(0));
            static assert(is(typeof(x) == size_t));
            t.release(size_t(0));
        }));
}

unittest
{
    import std.meta: AliasSeq;
    import std.traits: isNarrowString;
    static struct S1(T)
    {
        T[] window;
        size_t extend(size_t elements) { return 0; }
        void release(size_t elements) {}
    }

    // test struct with random access range instead of array
    import std.range: chain;
    static struct S2(T)
    {
        T[] arr1;
        T[] arr2;
        auto window() { return chain(arr1, arr2); }
        size_t extend(size_t elements) { return 0; }
        void release(size_t elements) {}
    }

    foreach(type; AliasSeq!(char, wchar, dchar, ubyte, byte, ushort, short, uint, int))
    {
        static assert(isIopipe!(S1!type), "S1!" ~ type.stringof);
        // Phobos treats narrow strings as non-random access range of dchar, so
        // compositions will not work with iopipe.
        static if(!isNarrowString!(type[]))
            static assert(isIopipe!(S2!type), "S2!" ~ type.stringof);
    }
}

// I don't know how to do this a better way...
template PropertyType(alias x)
{
    import std.traits: ReturnType;
    static if(is(typeof(x) == function))
        alias PropertyType = ReturnType!x;
    else
        alias PropertyType = typeof(x);
}

/**
 * Determine the type of the window of the given pipe type. This works when the
 * window is a method or a field.
 */
template WindowType(T)
{
    alias WindowType = PropertyType!(T.init.window);
}

unittest
{
    static struct S1 { ubyte[] window; }
    static assert(is(WindowType!S1 == ubyte[]));

    static struct S2 { ubyte[] window() { return null; } }
    static assert(is(WindowType!S2 == ubyte[]));
}

/**
 * Evaluates to true if the given io pipe has a valve
 */
template hasValve(T)
{
    import std.traits : hasMember;
    static if(hasMember!(T, "valve"))
        enum hasValve = isIopipe!T && isIopipe!(PropertyType!(T.init.valve));
    else
        enum hasValve = false;
}

/**
 * Boilerplate for implementing a valve. If you don't define a custom valve,
 * you should always mixin this template in all your iopipe templates.
 *
 * Params: pipechain - symbol that contains the upstream pipe chain.
 */
mixin template implementValve(alias pipechain)
{
    static if(hasValve!(PropertyType!(pipechain)))
        ref valve() { return pipechain.valve; }
}

unittest
{
    static struct S1
    {
        int[] valve;
        size_t extend(size_t elements) { return elements; }
        int[] window;
        void release(size_t elements) {}
    }

    static assert(hasValve!S1);

    static struct S2(T)
    {
        T upstream;
        size_t extend(size_t elements) { return elements; }
        int[] window;
        void release(size_t elements) {}

        mixin implementValve!(upstream);
    }

    static assert(hasValve!(S2!S1));
    static assert(!hasValve!(S2!(int[])));
}

/**
 * Determine the number of valves in the given pipeline
 */
template valveCount(T)
{
    static if(hasValve!(T))
    {
        enum valveCount = 1 + .valveCount!(PropertyType!(T.init.valve));
    }
    else
    {
        enum valveCount = 0;
    }
}

unittest
{
    static struct ValveStruct(T, bool shouldAddValve)
    {
        static if(shouldAddValve)
        {
            T valve;
        }
        else
        {
            T upstream;
            mixin implementValve!(upstream);
        }
        int[] window;
        size_t extend(size_t elements) { return elements; }
        void release(size_t elements) {}

    }

    static void foo(bool shouldAddValve, int curValves, int depth, T)(T t)
    {
        auto p = ValveStruct!(T, shouldAddValve)();
        enum myValves = curValves + (shouldAddValve? 1 : 0);
        static assert(valveCount!(typeof(p)) == myValves);
        static if(depth > 0)
        {
            foo!(true, myValves, depth - 1)(p);
            foo!(false, myValves, depth - 1)(p);
        }
    }

    foo!(true, 0, 4)((int[]).init);
    foo!(false, 0, 4)((int[]).init);
}
