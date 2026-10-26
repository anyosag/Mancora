/// The ImageJ macro language: a port of ImageJ 1.54p's `ij.macro` tokenizer
/// and interpreter, so macros written for ImageJ and Fiji run unchanged.
///
/// Built-in functions that touch images, selections, results or the user
/// interface go through a host that the embedding application provides;
/// the language itself (values, control flow, strings, arrays, math,
/// number formatting) lives here and has no other dependencies.
public enum MancoraMacro {}
