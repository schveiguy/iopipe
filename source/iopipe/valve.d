/**
 Valve mechanism to allow manipulation of wrapped iopipe pieces.
Copyright: Copyright Steven Schveighoffer 2011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy
           at http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.valve;
import iopipe.traits;
import std.traits : TemplateOf, isType;

private struct SimpleValve(Chain)
{
    Chain valve;

    auto window()
    {
        return valve.window;
    }

    void release(size_t elements)
    {
        valve.release(elements);
    }

    size_t extend(size_t elements)
    {
        return valve.extend(elements);
    }
}

/**
 * Create a simple valve in an iopipe chain.
 *
 * This puts a transparent layer between the given chain and the next downstream iopipe to provide valve access. Calling valve on the resulting iopipe gives access to the chain argument passed in.
 *
 * Params: chain = The upstream iopipe chain to provide valve access to.
 *
 * Returns: A new iopipe chain that provides a valve access point to the parameter.
 */
auto simpleValve(Chain)(Chain chain) if  (isIopipe!Chain)
{
    return SimpleValve!Chain(chain);
}

@safe unittest
{
    import iopipe.bufpipe;

    static struct MyPipe(Chain)
    {
        int addend;
        Chain chain;
        size_t extend(size_t elements)
        {
            auto newElems = chain.extend(elements);
            chain.window[$-newElems .. $] += addend;
            return newElems;
        }

        auto window() { return chain.window; }

        void release(size_t elements) { chain.release(elements); }
    }

    static auto simplePipe(size_t extendElementsDefault = 1, Chain)(Chain c)
    {
        return SimplePipe!(Chain, extendElementsDefault)(c);
    }

    // create two pipes strung together with valve access to the mypipe instance
    auto initialPipe = simplePipe([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    auto pipeline =  simplePipe(MyPipe!(typeof(initialPipe))(1, initialPipe).simpleValve);

    assert(pipeline.window.length == 0);
    assert(pipeline.extend(5) == 5);
    assert(pipeline.window == [2, 3, 4, 5, 6]);
    assert(!__traits(compiles, pipeline.addend = 2));
    pipeline.valve.addend = 2;
    assert(pipeline.extend(10) == 5);
    assert(pipeline.window == [2, 3, 4, 5, 6, 8, 9, 10, 11, 12]);
}

private struct HoldingValveInlet(Chain)
{
    private
    {
        Chain chain;
        size_t ready;
        size_t downstream;
    }

    auto window()
    {
        return chain.window[ready .. $];
    }

    // release data to the outlet
    void release(size_t elements)
    {
        assert(ready + elements <= chain.window.length);
        ready += elements;
    }

    size_t extend(size_t elements)
    {
        // get more data for inlet
        return chain.extend(elements);
    }

    mixin implementValve!(chain);
}

/**
 * Create a valve that uses a holding location to pass data from the inlet to the outlet.
 *
 * A holding valve allows one to manually control when data is released downstream. The holding valve consists of 3 parts:
 *  - An input buffer, controlled by an iopipe called the inlet. This gives access to the input parameter chain.
 *  - A holding area for data that has been released by the inlet to the outlet. This is basically a FIFO queue.
 *  - An output buffer, controlled by an iopipe called the outlet. This is the tail end of the holding valve, and provides data downstream.
 *
 * The inlet is a bit different than the normal iopipe, because it doesn't release data upstream, but rather downstream into the holding area.
 *
 * The outlet, when releasing data goes upstream with the release call, giving the data back to the buffered source.
 *
 * One major purpose of the holding valve is to use an autoValve to automate the downstream section, and let the user code interact directly with the inlet.
 *
 * For example, this creates effectively an output stream:
 *
 * ---------
 * import std.format;
 *
 * auto stream = bufferedSource!(char).holdingValve.outputFile("out.txt").autoValve;
 * stream.extend(100); // create a buffer of 100 characters (at least)
 *
 * void outputRange(const(char)[] str)
 * {
 *    if(stream.window.length < str.length)
 *       stream.extend(0); // extend as needed
 *    stream.window[0 .. str.length] = str;
 *    stream.release(str.length);
 * }
 * foreach(i; 0 .. 100)
 * {
 *    outputRange.formatValue(i);
 * }
 *
 * --------
 *
 * Params: chain = The upstream iopipe to which the valve controls access.
 * Returns: A valve assembly that gives access to the outlet via the return iopipe, and access to the inlet via the valve member.
 */
template holdingValve(Chain) if (isIopipe!Chain)
{
    struct Outlet
    {
        HoldingValveInlet!Chain valve;

        auto window()
        {
            return valve.chain.window[0 .. valve.downstream];
        }

        void release(size_t elements)
        {
            assert(elements <= valve.downstream);
            valve.chain.release(elements);
            valve.ready -= elements;
            valve.downstream -= elements;
        }

        size_t extend(size_t elements)
        {
            // ignore parameter, we can only push elements that have been released
            auto result = valve.ready - valve.downstream;
            valve.downstream = valve.ready;

            return result;
        }
    }

    auto holdingValve(Chain chain)
    {
        return Outlet(HoldingValveInlet!Chain(chain));
    }
}

/**
 * Create an auto-flushing valve loop. This is for use with a chain where the next
 * valve is a holding valve. What this does is automatically run the outlet of
 * the holding valve so it seamlessly flushes all data when required.
 *
 * Note that this will ONLY work if the first valve in the chain is a holdingValve.
 *
 * The valve loop provides the flush function which allows you to flush any
 * released data through the loop without extending. This function returns the
 * number of elements flushed.
 *
 * See holdingValve for a better explanation.
 */
template holdingLoop(Chain) if(hasValve!(Chain) && __traits(isSame, TemplateOf!(PropertyType!(Chain.init.valve)), HoldingValveInlet))
{
    struct AutoValve
    {
        Chain outlet;

        // needed for implementValve
        private ref inlet() { return outlet.valve; }

        auto window()
        {
            return inlet.window;
        }

        void release(size_t elements)
        {
            inlet.release(elements);
        }

        size_t extend(size_t elements)
        {
            // release any outstanding data that is on the outlet, this allows
            // the source buffer to reuse the data.
            flush();
            return inlet.extend(elements);
        }

        mixin implementValve!(inlet);

        // flush the data waiting in the outlet
        size_t flush()
        {
            outlet.extend(0);
            auto result = outlet.window.length;
            outlet.release(result);
            return result;
        }
    }

    auto holdingLoop(Chain chain)
    {
        return AutoValve(chain);
    }
}

unittest
{
    char[] destBuf;
    destBuf.reserve(100);


    struct writer(Chain)
    {
        Chain upstream;
        auto window() { return upstream.window; }
        size_t extend(size_t elements)
        {
            auto newElems = upstream.extend(elements);
            destBuf ~= upstream.window[$-newElems .. $];
            return newElems;
        }

        void release(size_t elements) { upstream.release(elements); }

        mixin implementValve!(upstream);
    }

    auto makeWriter(Chain)(Chain c)
    {
        return writer!(Chain)(c);
    }


    char[] sourceBuf = new char[100];
    auto pipeline = sourceBuf.simpleValve.push!(c => makeWriter(c));

    void write(string s)
    {
        pipeline.window[0 .. s.length] = s;
        pipeline.release(s.length);
    }

    assert(pipeline.window.length == 100);
    assert(destBuf.length == 0);
    // write some data
    write("hello");
    assert(pipeline.window.length == 95);
    assert(pipeline.valve.window.length == 100);
    assert(destBuf.length == 0);
    assert(pipeline.flush == 5);
    assert(destBuf == "hello");
    assert(pipeline.valve.window.length == 95);
    write(", world!");
    assert(pipeline.window.length == 87);
    assert(pipeline.valve.window.length == 95);
    assert(destBuf == "hello");
    assert(pipeline.extend(100) == 0); // cannot extend normal array automatically
    assert(pipeline.valve.window.length == 87);
    assert(destBuf == "hello, world!");

}

template autoFlush(Chain) if (__traits(hasMember, Chain, "flush"))
{
    struct AutoFlusher
    {
        Chain c;
        alias c this;
        static if(is(typeof((Chain c) @safe { c.flush(); })))
            ~this() @safe
            {
                c.flush();
            }
        else
            ~this() @system
            {
                c.flush();
            }
    }

    auto autoFlush(Chain c)
    {
        import iopipe.refc;
        return RefCounted!AutoFlusher(c);
    }
}

/**
 * Convenience mechanism to wrap a specified output pipeline with a holding
 * loop. It avoids having to explicitly specify the loop begin and end.
 *
 * Params:
 *    pipeline = a lambda template used to generate the pipeline that will
 *    be set up as a push chain.
 *    autoFlush = true (default) if you wish to auto-flush the push pipeline
 *    when all references to it are gone. This moves the whole chain into a
 *    RefCounted struct which automatically flushes any remaining data that
 *    hasn't been flushed.
 *    c = An ioPipe to be used as the source for the data being pushed.
 * Returns: A wrapped chain that will push any data that is released as needed
 * (i.e. as the buffer fills up).
 *
 * Note: If autoFlush is false, you will need to manually call flush on the
 * pipeline after all processing is done.
 */
auto push(alias pipeline, bool autoFlush = true, Chain)(Chain c) if (isIopipe!(typeof(pipeline(c.holdingValve))))
{
    static if(autoFlush)
    {
        import std.typecons: refCounted;
        return .autoFlush(pipeline(c.holdingValve).holdingLoop);
    }
    else
        return pipeline(c.holdingValve).holdingLoop;
}

// TODO: need good example to show how to use this.


/**
 * Go down the chain of valves until you find a valve of the given type. This
 * is useful if you know there is a pipe you are looking for in the chain of valves.
 *
 * Params:
 *     T = type or template of valve you are looking for
 *     pipe = iopipe you are searching
 *
 * Returns:
 *     a valve of the specified type or template. If such a valve doesn't
 *     exist, a static error occurs.
 */
auto valveOf(T, Chain)(ref Chain pipe) if (isType!T && isIopipe!Chain && hasValve!Chain)
{
    alias V = PropertyType!(pipe.valve);
    static if(is(V == T))
        return pipe.valve;
    else static if(is(typeof(.valveOf!T(pipe.valve))))
        return pipe.valve.valveOf!T;
    else
        static assert(0, "Pipe type " ~ Chain.stringof ~ " does not have valve of type " ~ T.stringof);
}

/// ditto
auto valveOf(alias X, Chain)(ref Chain pipe) if (!isType!X && isIopipe!Chain && hasValve!Chain)
{
    alias V = PropertyType!(pipe.valve);
    static if(__traits(isSame, TemplateOf!V, X))
        return pipe.valve;
    else static if(is(typeof(pipe.valve.valveOf!X)))
        return pipe.valve.valveOf!T;
    else
        static assert(0, "Pipe type " ~ Chain.stringof ~ " does not have valve based on template " ~ T.stringof);
}

@safe unittest
{
    string basepipe = "hello world";
    auto p = basepipe.simpleValve.simpleValve;
    assert(p.valveOf!string is basepipe);
    alias T = typeof(p.valveOf!SimpleValve);
    static assert(is(T == SimpleValve!string));
}
