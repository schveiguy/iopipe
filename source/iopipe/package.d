/**
 * iopipe is a modular buffering library based on range-like concepts.
 *
 * The goal of iopipe is to provide small building blocks that can
 * then be combined together in "pipeline" chain to provide the exact
 * representation needed for buffered input and output.
 *
 * The simple principal that iopipe is based on is that i/o needs to be
 * buffered, and since we are already creating a buffer for performance, we can
 * provide access to the buffer to enable much richer parsing and formatting
 * mechanisms. An iopipe chain can provide a window of data that can be used
 * with any algorithms or functions that work with simple arrays or ranges.
 *
 * This module publicly imports all of iopipe.
 */
module iopipe;

public import iopipe.bufpipe;
public import iopipe.buffer;
public import iopipe.textpipe;
public import iopipe.traits;
public import iopipe.zip;
public import iopipe.valve;
