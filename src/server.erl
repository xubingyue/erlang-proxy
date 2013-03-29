-module(server).

-export([start/0]).

-export([start_process/0,
        start_process/1,
        accept/1,
        start_server/0]).


-include("utils.hrl").
-include("config.hrl").

-define(CONNECT_RETRY_TIMES, 3).
-define(WORKER_NUMS, 30).
-define(WORKER_TIMEOUT, 300000).


-ifdef(debug).
-define(LOG(Msg, Args), io:format(Msg, Args)).
-else.
-define(LOG(Msg, Args), true).
-endif.




start() ->
    {ok, Socket} = gen_tcp:listen(?REMOTEPORT, ?OPTIONS({0,0,0,0})),
    ?LOG("Server listen on ~p~n", [?REMOTEPORT]),
    register(gate, self()),
    register(server, spawn(?MODULE, start_server, [])),
    accept(Socket).


accept(Socket) ->
    {ok, Client} = gen_tcp:accept(Socket),
    server ! choosepid,
    receive
        {ok, Pid} ->
            ok = gen_tcp:controlling_process(Client, Pid),
            Pid ! {connect, Client}
        after ?TIMEOUT ->
            gen_tcp:close(Client)
    end,
    accept(Socket).



start_server() ->
    start_server(start_works(?WORKER_NUMS)).

%% main loop, accept new connections, reuse works, and purge dead works.
start_server(Works) ->
    NewWorks =
    receive
        choosepid ->
            manage_works(choosepid, Works);
        {'DOWN', _Ref, process, Pid, timeout} ->
            manage_works(timeout, Works, Pid);
        {reuse, Pid} ->
            manage_works(reuse, Works, Pid)
    end,
    start_server(NewWorks).


%% spawn some works as works pool.
start_works(Num) ->
    start_works(Num, []).

start_works(0, Works) ->
    Works;
start_works(Num, Works) ->
    {Pid, _Ref} = spawn_monitor(?MODULE, start_process, []),
    start_works(Num-1, [Pid | Works]).






manage_works(choosepid, []) ->
    [Head | Tail] = start_works(?WORKER_NUMS),
    gate ! {ok, Head},
    Tail;

manage_works(choosepid, [Head | Tail]) ->
    gate ! {ok, Head},
    Tail.

manage_works(timeout, Works, Pid) ->
    ?LOG("Clear timeout pid: ~p~n", [Pid]),
    lists:delete(Pid, Works);

manage_works(reuse, Works, Pid) ->
    ?LOG("Reuse Pid, back to pool: ~p~n", [Pid]),
    Works ++ [Pid].
    



start_process() ->
    receive
        {connect, Client} -> 
            start_process(Client),
            server ! {reuse, self()},
            start_process()
    after ?WORKER_TIMEOUT ->
        exit(timeout)
    end.





start_process(Client) ->
    case gen_tcp:recv(Client, 1) of
        {ok, <<?IPV4>>} ->
            {ok, <<Port:16, Destination:32>>} = gen_tcp:recv(Client, 6),
            Address = list_to_tuple( binary_to_list(Destination) ),
            communicate(Client, Address, Port);
        {ok, <<?IPV6>>} ->
            {ok, <<Port:16, Destination:128>>} = gen_tcp:recv(Client, 18),
            Address = list_to_tuple( binary_to_list(Destination) ),
            communicate(Client, Address, Port);
        {ok, <<?DOMAIN>>} ->
            {ok, <<Port:16, DomainLen:8>>} = gen_tcp:recv(Client, 3),
            {ok, <<Destination/binary>>} = gen_tcp:recv(Client, DomainLen),
            Address = binary_to_list(Destination),
            communicate(Client, Address, Port);
        {error, _Error} ->
            io:format("start recv client error: ~p~n", [_Error]),
            gen_tcp:close(Client)
    end,
    ok.


communicate(Client, Address, Port) ->
    io:format("Address: ~p, Port: ~p~n", [Address, Port]),

    case connect_target(Address, Port, ?CONNECT_RETRY_TIMES) of
        {ok, TargetSocket} ->
            ok = inet:setopts(TargetSocket, [{active, true}]),
            ok = inet:setopts(Client, [{active, true}]),
            transfer(Client, TargetSocket);
        error ->
            ?LOG("Connect Address Error: ~p:~p~n", [Address, Port]),
            gen_tcp:close(Client)
    end.



connect_target(_, _, 0) ->
    error;
connect_target(Address, Port, Times) ->
    case gen_tcp:connect(Address, Port, ?OPTIONS, ?TIMEOUT) of
        {ok, TargetSocket} ->
            {ok, TargetSocket};
        {error, _Error} ->
            connect_target(Address, Port, Times-1)
    end.





transfer(Client, Remote) ->
    receive
        {tcp, Client, Request} ->
            ok = gen_tcp:send(Remote, Request),
            transfer(Client, Remote);
        {tcp, Remote, Response} ->
            ok = gen_tcp:send(Client, Response),
            transfer(Client, Remote);
        {tcp_closed, Client} ->
            ok;
        {tcp_closed, Remote} ->
            ok;
        {tcp_error, Client, _Reason} ->
            ok;
        {tcp_error, Remote, _Reason} ->
            ok
    end,

    gen_tcp:close(Remote),
    gen_tcp:close(Client),
    ok.


