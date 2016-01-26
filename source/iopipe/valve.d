/**
Copyright: Copyright Steven Schveighoffer 20011-.
License:   Boost License 1.0. (See accompanying file LICENSE_1_0.txt or copy at
           http://www.boost.org/LICENSE_1_0.txt)
Authors:   Steven Schveighoffer
 */
module iopipe.valve;
import std.traits : hasMember;

mixin template implementValve(alias chain)
{
    static if(hasMember!(typeof(chain), "valve"))
        ref valve() { return chain.valve; }
}

// provides a mechanism to hold data from downstream processors until ready
auto valved(Chain)(Chain chain)
{
    static struct Inlet
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
            import std.stdio;
            /*stderr.writeln("releasing ", elements, " elements to outlet");
            stderr.writefln("ready = %s, downstream = %s, chain.window.length = %s", ready, downstream, chain.window.length);*/
            assert(ready + elements <= chain.window.length);
            ready += elements;
        }

        size_t extend(size_t elements)
        {
            // get more data for inlet
            import std.stdio;
            //stderr.writefln("before extend, window.length == %s, ready = %s, downstream = %s", window.length, ready, downstream);
            //return chain.extend(elements);
            auto x = chain.extend(elements);
            //stderr.writefln("after extend, window.length == %s, ready = %s, downstream = %s, returning %s", window.length, ready, downstream, x);
            return x;
        }

        mixin implementValve!(chain);
    }

    static struct Outlet
    {
        Inlet valve;

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

    return Outlet(Inlet(chain));
}

// combine an inlet and outlet chain so the outlet is automatically flushed
// when needed
auto autoValve(Outlet)(Outlet o) if( hasMember!(Outlet, "valve") )
{
    static struct AutoValve
    {
        Outlet outlet;

        auto window()
        {
            return outlet.valve.window;
        }

        void release(size_t elements)
        {
            import std.stdio;
            //stderr.writeln("releasing ", elements, " elements");
            outlet.valve.release(elements);
        }

        size_t extend(size_t elements)
        {
            // release any outstanding data that is on the outlet, this allows
            // the source buffer to reuse the data.
            flush();
            return outlet.valve.extend(elements);
        }

        mixin implementValve!(outlet.valve);

        // flush the data waiting in the outlet
        size_t flush()
        {
            import std.stdio;
            //stderr.writeln("flush");
            outlet.extend(0);
            auto result = outlet.window.length;
            outlet.release(result);
            //stderr.writeln("flush done");
            return result;
        }
    }

    return AutoValve(o);
}
