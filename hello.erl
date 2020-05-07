-module(hello).
-export([init/0]).

init() -> io:fwrite("hello, world\n").
