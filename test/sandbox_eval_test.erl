-module(sandbox_eval_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , {timeout, 120, ?_test( t_basic() )}
    ].

t_basic() ->
    {Ctl, MRef} = morpheus_sandbox:start(
                    ?MODULE, basic_test_entry, [],
                    [ monitor
                    %% , verbose_handle, verbose_ctl
                    ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

-define(GH, morpheus_guest_helper).
-define(G, morpheus_guest).

basic_test_entry() ->
    Me = self(),
    spawn(fun () ->
                  Me ! a,
                  Me ! b
          end),

    {ok, Tokens, _} = erl_scan:string("receive b -> ok end."),
    {ok, Parsed} = erl_parse:parse_exprs(Tokens),
    {value, _, _} = erl_eval:exprs(Parsed, []),
    {messages, Msgs} = process_info(self(), messages),
    Msgs = [a],
    receive a -> ok end,
    ?G:exit_with(success),
    ok.
