Buffer pipe is a concept of a buffered stream that exposes a customizable window of the data at a given point.

Processor Primitives:

SomeRange window();
- Fetches the current window of data that has been processed and ready for use.
- Most processors will keep track of some data that isn't ready to send down.
- Should probably be inout (we'll see if it will work).
- Window should be based on upstream processor window, but can be cached until extend is called.
- Analogue to range.front()

void release(size_t elements)
- Release the given number of elements from the window.
- The only thing this MUST do is adjust the data that is returned via window()
- Should adjust any markers stored for the window, if the message is passed upstream.

size_t extend(size_t elements)
- Extend the current window by the given number of elements. 
- If elements is 0, the processor should extend at least one element.
- If no new data is going to be available without intervention, the return value is 0.
- Prototype of read().
- Standard practice if you are caching the released items is to call release first upstream and then extend, so unneeded data isn't copied.

ref valve()
- Go through the chain and find the next valve.
- If a valve exists upstream, the processor is REQUIRED to implement this (and should be implemented as return upstream.valve();) It MUST return by reference.
- If no valve exists upstream, the processor should NOT implement this.
- valve() is implemented on the actual valve as returning the Inlet processor of the valve (more below).
- Calling valve() on the inlet returns the next valve in the processing chain, or is not implemented if none exists.
- A mixin will be provided to implement the boilerplate.

release and extend are roughly equivalent to popFront and empty, although satisfy the API in a different way.

Note: extend returning 0 may not mean eof if manual intervention somewhere is required.

Processing:

Processing is handled on the extend function. Essentially the processor should prepare the data in order to pass down through the window.

Input:

The input (or pull) stream will be a simple chained call, with the final processor providing the final view of the data. This is the simplest case.

Output:

An output stream is really an input stream "folded in half". The fold point is the place where you can write to the buffer. Conceptually, it works by creating 2 input pipelines, where one is linked to the other. But the most downstream pipeline is run by an adapter that only processes when the buffer you are writing to is exhausted and you need to move things along.

This is accomplished by using valves.

Valves:

A "valve" is a point in the pipeline at which the flow of data can be controlled. The data provided to a valve is divided into 3 parts. There is a slice of data that is "work in progress", also defined as the inlet data. The valve inlet acts as a processor that releases data to the outlet. The second slice is the data that has been released from the inlet and ready for the outlet to retreive it. Because the outlet should not be given data it hasn't asked for, we need to keep this separate. The third slice is the "processed data" or oulet data. It is extended only by adding the data released from the inlet.

A valve has the same primitives as a processor, but depending on which end you are looking at (inlet or outlet), the primitives do different things.

Inlet:
- extend fetches more data from upstream chain
- release provides more data to outlet
- window gives data that has NOT been passed to outlet
- valve gets next valve upstream (if present)

Outlet:
- extend fetches any data from inlet. If no data is ready, it returns 0, but this MAY NOT be eof (one case where this can be true).
- release tells inlet and upstream chain to actually release the data.
- window gives data that has been extended from inlet.
- valve returns inlet.

A valve should not be used to implement inter-process or inter-thread I/O, since manual data release is not required (the process/thread/fiber can be put to sleep).

Moving/copying:

Moving/copying should be possible during construction of the pipeline. However, after processing has begun, copying cannot be allowed. Some parts of a chain may be value-based, in which case you are copying state that shouldn't be duplicated in multiple copies. Moving should be fine after processing has begun.

In some cases the stream must be partially processed in order to continue constructing the pipeline. In this case, any previous copies of the pipeline should no longer be used. (effectively a move).

Buffer:

The buffer supports some different primitives:

1. Get the current buffer window. This must be a random-access range with slicing ability. For the purposes of this library, char arrays and wchar arrays are considered arrays and not autodecoding ranges of dchar.
2. "Extend and flush" buffer. The buffer is passed 3 parameters to help it decide what to do:
  a. The number of elements at the *front* of the buffer that are no longer needed. The buffer must discard these, and is free to reuse them.
  b. The number of elements that are significant, including the bytes to discard. These start at the element identified by a. Essentially the window buffer.window[a..b] identifies the used data that is passed down the chain.
  c. The minimum number of elements to extend the buffer beyond the current "valid window". If 0 is passed, then no extension is necessary.

If "Extend and flush" function succeeds, the buffer MUST remove the elements identified by a, such that buffer.window[0..b-a] is the valid data. If it cannot extend the minimum number of elements, it must return failure, and the discarded elements left in place.

A use case for function 2: Let's say the object requesting a buffer extend and flush is a file input.
parameter a is simply the number of bytes that have already been processed and discarded by the pipeline. parameter b is the number of bytes still in use. parameter c should be the optimal number of bytes to read with a read() operation.

Source:

A source buffer processor translates from a non-processor type into a processor type. For example, an array is not a buffer processor. But a source buffer processor can easily do this. Likewise, a buffer is not a buffer processor, neither is a file input stream. But an adapter can use a file input stream and a buffer pair to create a buffer processor interface. Not sure if this needs to be identified specially, or generically. Likely there are many forms a source processor will take.
