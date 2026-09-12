/// A peer macro that expands to nothing, with a GENERIC, FUNCTION-TYPED parameter.
@attached(peer)
public macro Closure<In, Out>(_ f: (In) -> Out) = #externalMacro(module: "Impl", type: "NoOp")

/// The control: generic, but the parameter is a plain value.
@attached(peer)
public macro Value<T>(_ v: T) = #externalMacro(module: "Impl", type: "NoOp")
