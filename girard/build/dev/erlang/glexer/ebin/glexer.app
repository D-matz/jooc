{application, glexer, [
    {vsn, "2.5.0"},
    {applications, [gleam_stdlib,
                    splitter]},
    {description, "A lexer for Gleam source code"},
    {modules, [glexer,
               glexer@token,
               glexer_ffi]},
    {registered, []}
]}.
