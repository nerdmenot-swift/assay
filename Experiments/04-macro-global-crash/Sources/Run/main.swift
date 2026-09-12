import Lib

// THIS LINE CRASHES swift-frontend 6.3.3 (signal 11). Move it inside a struct or a
// function body and it compiles; change `@Closure` to `@Value` and it compiles.
@Closure({ (s: String) in s.count }) var a: Int = 0

print(a)
