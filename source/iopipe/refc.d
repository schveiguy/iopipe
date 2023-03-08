/**
 Reference counting using the GC.

 The RefCounted struct simply stores the item in a GC block, and also adds a
 root to that block. Once all known references to the block are removed
 (tracked by a reference count in the block), then the block is removed, and
 the destructor run. Since it's a root, it can run the full destructor of the
 data underneath, without worrying about GC data being collected underneath it.

 This depends on the block not being involved in a cycle, which should be fine
 for iopipes.

 Note that atomics are used for the reference count because the GC can destroy
 things in other threads.
 */
module iopipe.refc;

/**
 * A struct to ensure only one copy of the provided item exists.
 *
 * This differs from Phobos' std.typecons.RefCounted by using the GC to store
 * the memory, instead of C's heap. The benefit here is that this version of
 * RefCounted can be @safe.
 *
 * The block containing the item is pinned in the GC until all references are
 * gone, which means the destructor will be run synchronously when the last
 * reference is removed. Therefore, it is safe to store a RefCounted struct
 * inside a GC allocated type.
 */
struct RefCounted(T)
{
    /// Constructor. the underlying T is constructed using the parameters.
    this(Args...)(auto ref Args args)
    {
        import core.memory : GC;
        // need to use untyped memory, so we don't get a dtor call by the GC.
        import std.traits : hasIndirections;
        import std.conv : emplace;
        static if(hasIndirections!T)
            auto rawMem = new void[Impl.sizeof];
        else
            auto rawMem = new ubyte[Impl.sizeof];
        _impl = (() @trusted => cast(Impl*)rawMem.ptr)();
        emplace(_impl, args);
        () @trusted { GC.addRoot(_impl); }();
    }

    private struct Impl
    {
        this(ref T _item)
        {
            import std.algorithm : move;
            item = move(_item);
        }

        this(Args...)(auto ref Args args)
        {
            item = T(args);
        }
        T item;
        shared int _count = 1;
    }

    /** Get a reference to the item. Note that if you store a reference to this
    * item, it is possible the item will in the future be destroyed, but the
    * memory will still be present (until the GC cleans it up).
    */
    ref T _get() return
    {
        assert(_impl, "Invalid refcounted access");
        return _impl.item;
    }

    this(this)
    {
        if(_impl)
        {
            import core.atomic;
            _impl._count.atomicOp!"+="(1);
        }
    }

    ~this()
    {
        if(_impl)
        {
            assert(_impl._count > 0, "Invalid count detected");
            import core.atomic;
            if(_impl._count.atomicOp!"-="(1) == 0)
            {
                destroy(_impl.item);
                import core.memory : GC;
                () @trusted { GC.removeRoot(_impl); } ();
            }
            _impl = null;
        }
    }

    /// Assignment to another ref counted item.
    void opAssign(RefCounted other)
    {
        import std.algorithm : swap;
        swap(_impl, other._impl);
    }

    /// Assignment to another T.
    void opAssign(T other)
    {
        import std.algorithm : move;
        move(other, _impl.item);
    }

    /// Alias the item to this struct.
    alias _get this;

private:
    private Impl * _impl;
}

/// Return a ref counted version of the given item.
RefCounted!T refCounted(T)(auto ref T item)
{
    return RefCounted!T(item);
}

///
@safe unittest
{
    // note that destructor is called from the parameter to refCounted, so we
    // must trigger only counting destruction of non-init instances of the
    // struct.
    size_t dtorcalled = 0;
    struct S
    {
        int x;
        @safe ~this() {if(x) dtorcalled++;}
        @disable this(this);
    }

    {
        auto destroyme = S(1).refCounted;
        auto dm2 = destroyme;
        auto dm3 = destroyme;
    }

    assert(dtorcalled == 1);
}
