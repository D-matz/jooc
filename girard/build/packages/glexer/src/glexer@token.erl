-module(glexer@token).
-compile([no_auto_import, nowarn_ignored, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-export([to_source/1]).
-export_type([token/0]).

-type token() :: {name, binary()} | {upper_name, binary()} | {discard_name, binary()} | {int, binary()} | {float, binary()} | {string, binary()} | {comment_doc, binary()} | {comment_normal, binary()} | {comment_module, binary()} | as | assert | auto | 'case' | const | delegate | derive | echo | 'else' | fn | 'if' | implement | import | 'let' | macro | opaque | panic | pub | test | todo | type | use | left_paren | right_paren | left_brace | right_brace | left_square | right_square | plus | minus | star | slash | less | greater | less_equal | greater_equal | percent | plus_dot | minus_dot | star_dot | slash_dot | less_dot | greater_dot | less_equal_dot | greater_equal_dot | less_greater | at | colon | comma | hash | bang | equal | equal_equal | not_equal | v_bar | v_bar_v_bar | amper_amper | less_less | greater_greater | pipe | dot | dot_dot | left_arrow | right_arrow | end_of_file | {space, binary()} | {unterminated_string, binary()} | {unexpected_grapheme, binary()}.

-file("src/glexer/token.gleam", 100).
-spec to_source(token()) -> binary().
-doc(~" Turn a token back into its Gleam source representation.
").
to_source(Tok) ->
    case Tok of
        {name, Str} ->
            Str;

        {upper_name, Str@1} ->
            Str@1;

        {int, Str@2} ->
            Str@2;

        {float, Str@3} ->
            Str@3;

        {discard_name, Str@4} ->
            <<"_"/utf8, Str@4/binary>>;

        {string, Str@5} ->
            <<<<"\""/utf8, Str@5/binary>>/binary, "\""/utf8>>;

        {comment_doc, Str@6} ->
            <<"///"/utf8, Str@6/binary>>;

        {comment_normal, Str@7} ->
            <<"//"/utf8, Str@7/binary>>;

        {comment_module, Str@8} ->
            <<"////"/utf8, Str@8/binary>>;

        as ->
            ~"as";

        assert ->
            ~"assert";

        auto ->
            ~"auto";

        'case' ->
            ~"case";

        const ->
            ~"const";

        delegate ->
            ~"delegate";

        derive ->
            ~"derive";

        echo ->
            ~"echo";

        'else' ->
            ~"else";

        fn ->
            ~"fn";

        'if' ->
            ~"if";

        implement ->
            ~"implement";

        import ->
            ~"import";

        'let' ->
            ~"let";

        macro ->
            ~"macro";

        opaque ->
            ~"opaque";

        panic ->
            ~"panic";

        pub ->
            ~"pub";

        test ->
            ~"test";

        todo ->
            ~"todo";

        type ->
            ~"type";

        use ->
            ~"use";

        left_paren ->
            ~"(";

        right_paren ->
            ~")";

        left_brace ->
            ~"{";

        right_brace ->
            ~"}";

        left_square ->
            ~"[";

        right_square ->
            ~"]";

        plus ->
            ~"+";

        minus ->
            ~"-";

        star ->
            ~"*";

        slash ->
            ~"/";

        less ->
            ~"<";

        greater ->
            ~">";

        less_equal ->
            ~"<=";

        greater_equal ->
            ~">=";

        percent ->
            ~"%";

        plus_dot ->
            ~"+.";

        minus_dot ->
            ~"-.";

        star_dot ->
            ~"*.";

        slash_dot ->
            ~"/.";

        less_dot ->
            ~"<.";

        greater_dot ->
            ~">.";

        less_equal_dot ->
            ~"<=.";

        greater_equal_dot ->
            ~">=.";

        less_greater ->
            ~"<>";

        at ->
            ~"@";

        colon ->
            ~":";

        comma ->
            ~",";

        hash ->
            ~"#";

        bang ->
            ~"!";

        equal ->
            ~"=";

        equal_equal ->
            ~"==";

        not_equal ->
            ~"!=";

        v_bar ->
            ~"|";

        v_bar_v_bar ->
            ~"||";

        amper_amper ->
            ~"&&";

        less_less ->
            ~"<<";

        greater_greater ->
            ~">>";

        pipe ->
            ~"|>";

        dot ->
            ~".";

        dot_dot ->
            ~"..";

        left_arrow ->
            ~"<-";

        right_arrow ->
            ~"->";

        end_of_file ->
            ~"";

        {space, Str@9} ->
            Str@9;

        {unterminated_string, Str@10} ->
            <<"\""/utf8, Str@10/binary>>;

        {unexpected_grapheme, Str@11} ->
            Str@11
    end.

