/// Image processing that reproduces ImageJ's results: filters, type
/// conversions, stack projections and pixel arithmetic, each a port of the
/// ImageJ class named in its documentation and tested against values that
/// ImageJ 1.54p computed.
///
/// Operations take and return values (`Plane`, `ImageStack`,
/// `Hyperstack`) and never touch files or the user interface.
public enum MancoraProcess {}
